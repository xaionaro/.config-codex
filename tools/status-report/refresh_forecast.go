package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/goccy/go-yaml/token"
	"gopkg.in/yaml.v3"
)

// scalarEdit describes one bounded byte replacement.
//
// Example: Record a byte range and replacement text.
type scalarEdit struct {
	start, end int
	value      string
}

// refreshForecastTargets projects explicitly linked forecasts and reconciliation issues.
//
// Example: Update a linked lane forecast from its canonical record.
func refreshForecastTargets(dir, path string, info os.FileInfo, original, candidate []byte) error {
	ledgerPath := filepath.Join(dir, "project-understanding.yaml")
	forecastPath := filepath.Join(dir, "forecasts.yaml")
	ledgerBytes, err := os.ReadFile(ledgerPath)
	if err != nil {
		return err
	}
	var ledger ledgerSource
	var forecasts forecastSource
	if err := readSource(ledgerPath, &ledger); err != nil {
		return err
	}
	if ledger.Schema != "project-understanding/v1" || ledger.Records == nil {
		return fmt.Errorf("unsupported sources")
	}
	var forecastBytes []byte
	if hasForecastReference(ledger) {
		forecastBytes, err = os.ReadFile(forecastPath)
		if err != nil {
			return err
		}
		if err := readSource(forecastPath, &forecasts); err != nil {
			return err
		}
		if forecasts.Schema != "forecasts/v1" || forecasts.Records == nil {
			return fmt.Errorf("unsupported forecasts")
		}
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(candidate, &doc); err != nil {
		return err
	}
	root := doc.Content[0]
	edits, err := collectForecastEdits(candidate, root, ledger, forecasts, &flowDocument{data: candidate})
	if err != nil {
		return err
	}
	sort.Slice(edits,
		// Callback orders edits from later offsets to earlier offsets.
		//
		// Example: Apply disjoint edits without shifting later offsets.
		func(i, j int) bool { return edits[i].start > edits[j].start })
	updated := append([]byte(nil), candidate...)
	for _, e := range edits {
		updated = append(append(append([]byte(nil), updated[:e.start]...), []byte(e.value)...), updated[e.end:]...)
	}
	report, err := parse(updated)
	if err != nil {
		return fmt.Errorf("refreshed report invalid: %w", err)
	}
	issues := reconcile(report, dir)
	sort.Strings(issues)
	for _, issue := range issues {
		if issue == "report declares scope incomplete" {
			continue
		}
		updated, err = prepareInvalidation(updated, "Status refresh incomplete: "+issue)
		if err != nil {
			return err
		}
	}
	if bytes.Equal(updated, original) {
		return nil
	}
	if err := verifyRefresh(original, updated, ledger, forecasts); err != nil {
		return fmt.Errorf("unsafe refresh: %w", err)
	}
	inputs := map[string][]byte{ledgerPath: ledgerBytes}
	if forecastBytes != nil {
		inputs[forecastPath] = forecastBytes
	}
	return publishStatus(dir, path, info, original, updated, inputs)
}

// hasForecastReference reports whether work references a canonical forecast.
//
// Example: Determine whether a session needs a forecast file.
func hasForecastReference(ledger ledgerSource) bool {
	for _, record := range ledger.Records {
		if record.Type == "work" && record.Data.ForecastRef != "" {
			return true
		}
	}
	return false
}

// validateRefreshSource checks that a forecast source supports a complete projection.
//
// Example: Reject a provisional forecast without a target basis.
func validateRefreshSource(source map[string]any) error {
	for key := range source {
		switch key {
		case "kind", "status", "outcome", "target", "assessment", "original_baseline", "baseline_evidence", "recalibration", "target_basis", "base_case", "scenarios":
		default:
			return fmt.Errorf("unsupported source field %s", key)
		}
	}
	for _, field := range []string{"outcome", "target", "assessment", "original_baseline", "baseline_evidence"} {
		if textField(source, field) == "" {
			return fmt.Errorf("missing %s", field)
		}
	}
	if _, err := parseUTC(textField(source, "target")); err != nil {
		return fmt.Errorf("invalid target: %w", err)
	}
	assessment := textField(source, "assessment")
	if assessment != "complete" && assessment != "provisional" {
		return fmt.Errorf("invalid assessment")
	}
	if assessment == "provisional" && textField(source, "target_basis") == "" {
		return fmt.Errorf("missing target_basis")
	}
	recal, ok := source["recalibration"].(map[string]any)
	if !ok || (textField(recal, "status") != "unchanged" && textField(recal, "status") != "changed") || textField(recal, "evidence") == "" {
		return fmt.Errorf("invalid recalibration")
	}
	if textField(recal, "status") == "changed" {
		if err := validateChangedRecalibration(recal, source); err != nil {
			return err
		}
	}
	if issues := forecastStructure(source); len(issues) > 0 {
		return fmt.Errorf("%s", strings.Join(issues, "; "))
	}
	return nil
}

// validateChangedRecalibration checks the evidence and current target of a changed forecast.
//
// Example: Check that recalibration current equals the target.
func validateChangedRecalibration(recal, source map[string]any) error {
	for _, key := range []string{"prior", "current", "reason"} {
		if textField(recal, key) == "" {
			return fmt.Errorf("recalibration missing %s", key)
		}
	}
	if !sameValue(textField(recal, "current"), textField(source, "target")) {
		return fmt.Errorf("recalibration current does not match target")
	}
	return nil
}

// hasOpenRoot finds an open root work record for a forecast reference.
//
// Example: Match a root forecast to its active work record.
func hasOpenRoot(ledger ledgerSource, ref string) bool {
	for _, record := range ledger.Records {
		if record.Type != "work" || record.Data.ForecastRef != ref || (record.Data.State != "active" && record.Data.State != "blocked") {
			continue
		}
		if slices.Contains(record.Data.Roles, "root") {
			return true
		}
	}
	return false
}

// mapValue looks up a key in a YAML mapping node.
//
// Example: Find the forecast reference in a YAML mapping.
func mapValue(n *yaml.Node, key string) *yaml.Node {
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}

// scalarReplacement prepares a bounded edit for a proven single-line scalar.
//
// Example: Prepare a target timestamp replacement.
func scalarReplacement(doc *flowDocument, node *yaml.Node, value string) (scalarEdit, error) {
	if node.Style&(yaml.LiteralStyle|yaml.FoldedStyle) != 0 {
		return scalarEdit{}, fmt.Errorf("multiline forecast scalar requires manual refresh")
	}
	start, end, err := doc.scalarSpan(node)
	if err != nil {
		return scalarEdit{}, err
	}
	return scalarEdit{start, end, strconv.Quote(value)}, nil
}

// projectForecast prepares canonical edits for a linked forecast.
//
// Example: Update a linked forecast from its source record.
func projectForecast(original []byte, node *yaml.Node, source map[string]any, doc *flowDocument) ([]scalarEdit, error) {
	fields := map[string]any{}
	for dst, src := range map[string]string{"outcome": "outcome", "target": "target", "assessment": "assessment", "baseline": "original_baseline"} {
		if value := textField(source, src); value != "" {
			fields[dst] = value
		}
	}
	if recal, ok := source["recalibration"].(map[string]any); ok {
		if err := projectRecalibration(fields, node, recal); err != nil {
			return nil, err
		}
	}
	projection := map[string]any{}
	for _, k := range []string{"target_basis", "baseline_evidence", "base_case", "scenarios"} {
		if v, ok := source[k]; ok {
			projection[k] = v
		}
	}
	if len(projection) > 0 {
		fields["source_projection"] = projection
	}
	var edits []scalarEdit
	var missing []string
	for key, value := range fields {
		existing := mapValue(node, key)
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		if existing == nil {
			missing = append(missing, strconv.Quote(key)+": "+string(encoded))
			continue
		}
		if key == "source_projection" {
			var current any
			if err := existing.Decode(&current); err != nil {
				return nil, err
			}
			if !projectionEqual(current, value) {
				edit, err := projectionReplacement(original, existing, string(encoded), doc)
				if err != nil {
					return nil, err
				}
				edits = append(edits, edit)
			}
			continue
		}
		str, ok := value.(string)
		if !ok || existing.Kind != yaml.ScalarNode || sameValue(existing.Value, str) {
			continue
		}
		edit, err := scalarReplacement(doc, existing, str)
		if err != nil {
			return nil, err
		}
		edits = append(edits, edit)
	}
	if len(missing) == 0 {
		return edits, nil
	}
	sort.Strings(missing)
	if node.Style&yaml.FlowStyle == 0 {
		end, indent, err := blockMappingEnd(original, node)
		if err != nil {
			return nil, err
		}
		var addition strings.Builder
		for _, field := range missing {
			addition.WriteString(strings.Repeat(" ", indent) + field + "\n")
		}
		edits = append(edits, scalarEdit{end, end, addition.String()})
		return edits, nil
	}
	end, err := flowMappingEndCached(doc, node)
	if err != nil {
		return nil, err
	}
	prefix := ""
	if len(node.Content) > 0 {
		prefix = ", "
	}
	edits = append(edits, scalarEdit{end, end, prefix + strings.Join(missing, ", ")})
	return edits, nil
}

// projectRecalibration prepares supported recalibration fields.
//
// Example: Copy the source evidence into a forecast projection.
func projectRecalibration(fields map[string]any, node *yaml.Node, recal map[string]any) error {
	for _, k := range []string{"prior", "reason", "evidence"} {
		if value := textField(recal, k); value != "" {
			fields[k] = value
		} else if mapValue(node, k) != nil {
			return fmt.Errorf("stale %s requires manual refresh", k)
		}
	}
	return nil
}

// projectionReplacement prepares a safe replacement of a source projection.
//
// Example: Replace a comment-free source projection mapping.
func projectionReplacement(data []byte, node *yaml.Node, value string, doc *flowDocument) (scalarEdit, error) {
	if node.Kind != yaml.MappingNode {
		return scalarEdit{}, fmt.Errorf("unsupported source_projection layout")
	}
	start, err := yamlByteOffset(data, node.Line, node.Column)
	if err != nil {
		return scalarEdit{}, err
	}
	if node.Style&yaml.FlowStyle != 0 {
		end, err := flowMappingEndCached(doc, node)
		if err != nil {
			return scalarEdit{}, err
		}
		if bytes.Contains(data[start:end+1], []byte("#")) {
			return scalarEdit{}, fmt.Errorf("source_projection contains comments; manual refresh required")
		}
		return scalarEdit{start, end + 1, value}, nil
	}
	end, _, err := blockMappingEnd(data, node)
	if err != nil {
		return scalarEdit{}, err
	}
	if bytes.Contains(data[start:end], []byte("#")) {
		return scalarEdit{}, fmt.Errorf("source_projection contains comments; manual refresh required")
	}
	return scalarEdit{start, end, value + "\n"}, nil
}

// blockMappingEnd finds a supported block mapping boundary.
//
// Example: Locate the boundary after a block-style forecast.
func blockMappingEnd(data []byte, node *yaml.Node) (int, int, error) {
	lines := strings.Split(string(data), "\n")
	if node.Line < 1 || node.Line > len(lines) {
		return 0, 0, fmt.Errorf("invalid block forecast location")
	}
	indent := node.Column - 1
	offset := 0
	for i, line := range lines {
		if i > node.Line-1 && strings.TrimSpace(line) != "" {
			leading := len(line) - len(strings.TrimLeft(line, " "))
			if leading < indent {
				return offset, indent, nil
			}
		}
		offset += len(line) + 1
	}
	return len(data), indent, nil
}

// flowMappingEnd locates a flow mapping boundary from YAML node coordinates.
//
// Example: Locate the closing brace of a flow forecast.
func flowMappingEnd(data []byte, node *yaml.Node) (int, error) {
	return flowMappingEndCached(&flowDocument{data: data}, node)
}

// flowMappingEndCached locates a flow mapping boundary using cached lexer pairs.
//
// Example: Reuse paired delimiters for a second forecast.
func flowMappingEndCached(doc *flowDocument, node *yaml.Node) (int, error) {
	start, err := yamlByteOffset(doc.data, node.Line, node.Column)
	if err != nil {
		return 0, err
	}
	return doc.end(start, token.MappingStartType)
}

// collectForecastEdits gathers edits for explicitly linked forecasts.
//
// Example: Collect linked lane and root forecast updates.
func collectForecastEdits(candidate []byte, root *yaml.Node, ledger ledgerSource, forecasts forecastSource, doc *flowDocument) ([]scalarEdit, error) {
	var edits []scalarEdit
	for _, kind := range []string{"lanes", "root_forecasts"} {
		collection := mapValue(root, kind)
		if collection == nil || collection.Kind != yaml.SequenceNode {
			continue
		}
		next, err := collectForecastGroup(candidate, collection, kind, ledger, forecasts, doc)
		if err != nil {
			return nil, err
		}
		edits = append(edits, next...)
	}
	return edits, nil
}

// collectForecastGroup gathers edits for one forecast group.
//
// Example: Collect updates for all report lanes.
func collectForecastGroup(candidate []byte, collection *yaml.Node, kind string, ledger ledgerSource, forecasts forecastSource, doc *flowDocument) ([]scalarEdit, error) {
	var edits []scalarEdit
	for _, item := range collection.Content {
		next, err := forecastItemEdits(candidate, item, kind, ledger, forecasts, doc)
		if err != nil {
			return nil, err
		}
		edits = append(edits, next...)
	}
	return edits, nil
}

// forecastItemEdits prepares edits for a single linked forecast.
//
// Example: Update the forecast linked to an active lane.
func forecastItemEdits(candidate []byte, item *yaml.Node, kind string, ledger ledgerSource, forecasts forecastSource, doc *flowDocument) ([]scalarEdit, error) {
	forecast := item
	if kind == "lanes" {
		forecast = mapValue(item, "forecast")
		work := mapValue(item, "work_ref")
		if forecast == nil || work == nil || !validRef(work.Value, "project-understanding.yaml") {
			return nil, nil
		}
		record, ok := ledger.Records[sourceID(work.Value, "project-understanding.yaml")]
		if !ok || record.Type != "work" || (record.Data.State != "active" && record.Data.State != "blocked") {
			return nil, nil
		}
		ref := mapValue(forecast, "forecast_ref")
		if ref == nil || ref.Value != record.Data.ForecastRef {
			return nil, nil
		}
	}
	ref := mapValue(forecast, "forecast_ref")
	if ref == nil || !validRef(ref.Value, "forecasts.yaml") {
		return nil, nil
	}
	expected := "lane"
	if kind == "root_forecasts" {
		expected = "root"
		if !hasOpenRoot(ledger, ref.Value) {
			return nil, nil
		}
	}
	source, ok := forecasts.Records[sourceID(ref.Value, "forecasts.yaml")]
	if !ok || textField(source, "kind") != expected || textField(source, "status") != "active" {
		return nil, fmt.Errorf("forecast %s missing or not an active %s forecast", ref.Value, expected)
	}
	if err := validateRefreshSource(source); err != nil {
		return nil, fmt.Errorf("forecast %s: %w", ref.Value, err)
	}
	edits, err := projectForecast(candidate, forecast, source, doc)
	if err != nil {
		return nil, fmt.Errorf("forecast %s: %w", ref.Value, err)
	}
	return edits, nil
}
