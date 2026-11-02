package main

import (
	"fmt"
	"reflect"
	"strings"

	"github.com/goccy/go-yaml/lexer"
	"github.com/goccy/go-yaml/token"
	"gopkg.in/yaml.v3"
)

// verifyRefresh preserves all nonprojected values and the ordered comment stream.
//
// Example: Reject a candidate that changes an unrelated task.
func verifyRefresh(
	original []byte,
	candidate []byte,
	ledger ledgerSource,
	forecasts forecastSource,
) error {
	beforeComments, err := yamlComments(original)
	if err != nil {
		return err
	}
	afterComments, err := yamlComments(candidate)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(beforeComments, afterComments) {
		return fmt.Errorf("refresh would change YAML comments")
	}
	var before, after map[string]any
	if err := yaml.Unmarshal(original, &before); err != nil {
		return err
	}
	if err := yaml.Unmarshal(candidate, &after); err != nil {
		return err
	}
	if err := verifyScopeAndDiagnostics(before, after); err != nil {
		return err
	}
	report, err := parse(original)
	if err != nil {
		return fmt.Errorf("invalid original report: %w", err)
	}
	if err := verifyForecastChanges(before, after, ledger, forecasts, reportLaneRefs(report)); err != nil {
		return err
	}
	if !reflect.DeepEqual(before, after) {
		return fmt.Errorf("refresh would change unprojected report values")
	}
	return nil
}

// yamlComments extracts the ordered YAML comment-token values.
//
// Example: Compare comments before and after a report update.
func yamlComments(data []byte) ([]string, error) {
	normalized := strings.ReplaceAll(strings.ReplaceAll(string(data), "\r\n", "\n"), "\r", "\n")
	tokens := lexer.Tokenize(normalized)
	if bad := tokens.InvalidToken(); bad != nil {
		return nil, fmt.Errorf("unsupported YAML token: %s", bad.Error)
	}
	var comments []string
	for _, t := range tokens {
		if t.Type == token.CommentType {
			comments = append(comments, t.Value)
		}
	}
	return comments, nil
}

// verifyScopeAndDiagnostics checks that scope and blocker changes are permitted.
//
// Example: Reject removal of an existing blocker.
func verifyScopeAndDiagnostics(
	before map[string]any,
	after map[string]any,
) error {
	if !reflect.DeepEqual(before["scope_complete"], after["scope_complete"]) && after["scope_complete"] != false {
		return fmt.Errorf("invalid scope change")
	}
	delete(before, "scope_complete")
	delete(after, "scope_complete")
	a, okA := before["blockers_risks"].([]any)
	b, okB := after["blockers_risks"].([]any)
	if !okA || !okB || len(b) < len(a) {
		return fmt.Errorf("invalid diagnostic change")
	}
	for i, v := range a {
		if !reflect.DeepEqual(v, b[i]) {
			return fmt.Errorf("refresh would change existing blockers")
		}
	}
	for _, v := range b[len(a):] {
		s, ok := v.(string)
		if !ok || (s != refreshDiagnostic && !strings.HasPrefix(s, refreshIssuePrefix)) {
			return fmt.Errorf("invalid refresh diagnostic")
		}
	}
	delete(before, "blockers_risks")
	delete(after, "blockers_risks")
	return nil
}

// verifyForecastChanges checks forecast changes against their canonical sources.
//
// Example: Reject an unlinked forecast change.
func verifyForecastChanges(
	before map[string]any,
	after map[string]any,
	ledger ledgerSource,
	forecasts forecastSource,
	laneRefs []string,
) error {
	for _, group := range []string{"lanes", "root_forecasts"} {
		a, _ := before[group].([]any)
		b, _ := after[group].([]any)
		if len(a) != len(b) {
			return fmt.Errorf("refresh would change forecast groups")
		}
		if err := verifyForecastGroup(group, a, b, ledger, forecasts, laneRefs); err != nil {
			return err
		}
	}
	return nil
}

// verifyForecastGroup checks one group of linked forecast changes.
//
// Example: Check linked forecasts in the lane list.
func verifyForecastGroup(
	group string,
	before []any,
	after []any,
	ledger ledgerSource,
	forecasts forecastSource,
	laneRefs []string,
) error {
	for i := range before {
		left, ok1 := before[i].(map[string]any)
		right, ok2 := after[i].(map[string]any)
		if !ok1 || !ok2 {
			return fmt.Errorf("unsupported forecast group")
		}
		forecastLeft, forecastRight, ref := linkedForecastMaps(group, left, right, ledger, laneRefs)
		if ref == "" {
			continue
		}
		source, ok := forecasts.Records[sourceID(ref, "forecasts.yaml")]
		if !ok {
			continue
		}
		if err := verifyProjectedFields(forecastLeft, forecastRight, source); err != nil {
			return fmt.Errorf("forecast %s: %w", ref, err)
		}
	}
	return nil
}

// linkedForecastMaps finds the corresponding maps for an explicitly linked forecast.
//
// Example: Find a lane and its referenced forecast mapping.
func linkedForecastMaps(
	group string,
	left map[string]any,
	right map[string]any,
	ledger ledgerSource,
	laneRefs []string,
) (map[string]any, map[string]any, string) {
	a, b := left, right
	if group == "lanes" {
		work, _ := left["work_ref"].(string)
		if !validRef(work, "project-understanding.yaml") {
			return nil, nil, ""
		}
		record, ok := ledger.Records[sourceID(work, "project-understanding.yaml")]
		if !ok || !forecastApplicable(record, "lane", false) {
			return nil, nil, ""
		}
		a, _ = left["forecast"].(map[string]any)
		b, _ = right["forecast"].(map[string]any)
		if a == nil || b == nil || a["forecast_ref"] != string(record.Data.ForecastRef) {
			return nil, nil, ""
		}
	}
	ref, ok := a["forecast_ref"].(string)
	if !ok || !validRef(ref, "forecasts.yaml") || b["forecast_ref"] != ref {
		return nil, nil, ""
	}
	if group == "root_forecasts" && !hasApplicableRoot(ledger, ref, laneRefs) {
		return nil, nil, ""
	}
	return a, b, ref
}

// verifyProjectedFields checks changed fields against canonical forecast values.
//
// Example: Reject a target that differs from the source.
func verifyProjectedFields(
	before map[string]any,
	after map[string]any,
	source map[string]any,
) error {
	expected := map[string]any{}
	for dst, src := range map[string]string{"outcome": "outcome", "target": "target", "assessment": "assessment", "baseline": "original_baseline"} {
		if v, ok := source[src]; ok {
			expected[dst] = v
		}
	}
	if recal, ok := source["recalibration"].(map[string]any); ok {
		copyRecalibrationFields(expected, recal)
	}
	projection := map[string]any{}
	for _, k := range []string{"target_basis", "baseline_evidence", "base_case", "scenarios"} {
		if v, ok := source[k]; ok {
			projection[k] = v
		}
	}
	if len(projection) > 0 {
		expected["source_projection"] = projection
	}
	for key, want := range expected {
		if reflect.DeepEqual(before[key], after[key]) {
			continue
		}
		if !projectionEqual(after[key], want) {
			return fmt.Errorf("unexpected projected %s", key)
		}
		delete(before, key)
		delete(after, key)
	}
	return nil
}

// copyRecalibrationFields copies supported recalibration values into a projection.
//
// Example: Copy prior target, reason and evidence.
func copyRecalibrationFields(
	expected map[string]any,
	recal map[string]any,
) {
	for _, k := range []string{"prior", "reason", "evidence"} {
		if v, ok := recal[k]; ok {
			expected[k] = v
		}
	}
}
