package main

import (
	"bytes"
	"strconv"
	"strings"

	"github.com/goccy/go-yaml/token"
	"gopkg.in/yaml.v3"
)

// validNarrativeSyncUpdate accepts explicit fields for a keyed narrative subject.
//
// Example: A progress update identifies its subject and supplies text.
func validNarrativeSyncUpdate(u syncUpdate) bool {
	switch u.Target {
	case syncTargetProgress, syncTargetDecisions, syncTargetBlockers, syncTargetVerification:
	default:
		return false
	}
	if strings.TrimSpace(u.ID) == "" || len(u.Fields) == 0 {
		return false
	}
	for k, v := range u.Fields {
		if (k != "text" && k != "evidence") || strings.TrimSpace(v) == "" {
			return false
		}
	}
	return true
}

// applyNarrativeSyncField projects one field without replacing owner-authored content.
//
// Example: A previously projected subject can receive newer text.
func applyNarrativeSyncField(
	data []byte,
	u syncUpdate,
	field string,
	value string,
	previous string,
	previousPresent bool,
	itemOwned bool,
) ([]byte, bool) {
	if !validNarrativeSyncUpdate(syncUpdate{Target: u.Target, ID: u.ID, Fields: map[string]string{field: value}}) {
		return data, false
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return data, false
	}
	root := doc.Content[0]
	list := mapValue(root, u.Target.String())
	if list == nil || list.Kind != yaml.SequenceNode {
		return data, false
	}
	var item *yaml.Node
	for _, n := range list.Content {
		if n.Kind != yaml.MappingNode {
			continue
		}
		ref := mapValue(n, "subject_ref")
		if ref != nil && ref.Value == u.ID {
			if item != nil {
				return data, false
			}
			item = n
		}
	}
	if item == nil {
		if field != "text" || previousPresent {
			return data, false
		}
		entry := "{subject_ref: " + strconv.Quote(u.ID) + ", text: " + strconv.Quote(value) + "}"
		if root.Style&yaml.FlowStyle != 0 {
			entry = "{\"subject_ref\": " + strconv.Quote(u.ID) + ", \"text\": " + strconv.Quote(value) + "}"
		}
		return appendNarrativeEntry(data, root, list, u.Target.String(), entry)
	}
	if field == "evidence" && !itemOwned {
		return data, false
	}
	existing := mapValue(item, field)
	if existing != nil {
		if !previousPresent || previous == "" || existing.Kind != yaml.ScalarNode || existing.Value != previous {
			return data, false
		}
	}
	if existing == nil && (previousPresent || !itemOwned) {
		return data, false
	}
	var fields forecastFieldEdits
	if fields.add(data, item, field, value, &flowDocument{data: data}) != nil {
		return data, false
	}
	if len(fields.Missing) != 0 {
		var end int
		var err error
		var insertion string
		if item.Style&yaml.FlowStyle != 0 {
			end, err = flowMappingEndCached(&flowDocument{data: data}, item)
			insertion = ", " + fields.Missing[0]
		} else {
			var indent int
			end, indent, err = blockMappingEnd(data, item)
			insertion = strings.Repeat(" ", indent) + fields.Missing[0] + "\n"
		}
		if err != nil {
			return data, false
		}
		return append(append(append([]byte(nil), data[:end]...), insertion...), data[end:]...), true
	}
	if len(fields.Edits) == 0 && existing != nil && existing.Value == value {
		return data, true
	}
	if len(fields.Edits) != 1 {
		return data, false
	}
	e := fields.Edits[0]
	return append(append(append([]byte(nil), data[:e.Start]...), e.Value...), data[e.End:]...), true
}

// appendNarrativeEntry appends a keyed item while preserving surrounding report bytes.
//
// Example: A flow list retains its existing scalar bullets and comments.
func appendNarrativeEntry(
	data []byte,
	root *yaml.Node,
	list *yaml.Node,
	section string,
	entry string,
) ([]byte, bool) {
	if list.Style&yaml.FlowStyle != 0 {
		start, err := yamlByteOffset(data, list.Line, list.Column)
		if err != nil {
			return data, false
		}
		end, err := flowEnd(data, start, token.SequenceStartType)
		if err != nil {
			return data, false
		}
		sep := ""
		if len(list.Content) > 0 {
			sep = ", "
		}
		return append(append(append([]byte(nil), data[:end]...), sep+entry...), data[end:]...), true
	}
	lines := strings.Split(string(data), "\n")
	insert := len(lines)
	if next := nextMappingFieldLine(root, section); next > 0 {
		insert = next - 1
	}
	indent := "  "
	if len(list.Content) > 0 {
		last := list.Content[len(list.Content)-1]
		if last.Line < 1 || last.Line > len(lines) {
			return data, false
		}
		dash := strings.Index(lines[last.Line-1], "- ")
		if dash < 0 || strings.TrimSpace(lines[last.Line-1][:dash]) != "" {
			return data, false
		}
		indent = lines[last.Line-1][:dash]
		insert = trimFollowingComments(lines, insert, last.Line)
	}
	if insert < 0 || insert > len(lines) {
		return data, false
	}
	ending := ""
	if bytes.Contains(data, []byte("\r\n")) {
		ending = "\r"
	}
	if insert == len(lines) && len(data) > 0 && data[len(data)-1] != '\n' {
		lines[insert-1] += ending
		ending = ""
	}
	lines = append(lines[:insert], append([]string{indent + "- " + entry + ending}, lines[insert:]...)...)
	return []byte(strings.Join(lines, "\n")), true
}

// narrativeSyncItemOwned verifies that exactly one subject retains its managed text.
//
// Example: An owner edit prevents subsequent automatic evidence changes.
func narrativeSyncItemOwned(
	data []byte,
	u syncUpdate,
	previousText string,
	previousTextPresent bool,
) bool {
	if !previousTextPresent || previousText == "" {
		return false
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return false
	}
	list := mapValue(doc.Content[0], u.Target.String())
	if list == nil || list.Kind != yaml.SequenceNode {
		return false
	}
	found := false
	for _, item := range list.Content {
		if item.Kind != yaml.MappingNode {
			continue
		}
		ref := mapValue(item, "subject_ref")
		if ref == nil || ref.Value != u.ID {
			continue
		}
		if found {
			return false
		}
		text := mapValue(item, "text")
		if text == nil || text.Kind != yaml.ScalarNode || text.Value != previousText {
			return false
		}
		found = true
	}
	return found
}

// retractNarrativeSync removes an unchanged managed subject and its managed evidence.
//
// Example: A correction removes its own keyed progress entry while preserving legacy bullets.
func retractNarrativeSync(
	data []byte,
	update syncUpdate,
	previousText string,
	previousTextPresent bool,
	previousEvidence string,
	previousEvidencePresent bool,
) ([]byte, bool) {
	if !narrativeSyncItemOwned(data, update, previousText, previousTextPresent) {
		return data, false
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return data, false
	}
	root := doc.Content[0]
	list := mapValue(root, update.Target.String())
	for index, item := range list.Content {
		if item.Kind != yaml.MappingNode {
			continue
		}
		ref := mapValue(item, "subject_ref")
		if ref == nil || ref.Value != update.ID {
			continue
		}
		evidence := mapValue(item, "evidence")
		if evidence == nil && previousEvidencePresent {
			return data, false
		}
		if evidence != nil && (!previousEvidencePresent || previousEvidence == "" || evidence.Kind != yaml.ScalarNode || evidence.Value != previousEvidence) {
			return data, false
		}
		if len(item.Content) != 4 && len(item.Content) != 6 {
			return data, false
		}
		for i := 0; i < len(item.Content); i += 2 {
			switch item.Content[i].Value {
			case "subject_ref", "text", "evidence":
			default:
				return data, false
			}
		}
		if list.Style&yaml.FlowStyle == 0 {
			return retractBlockNarrative(data, root, list, item, update.Target.String(), index)
		}
		if item.Style&yaml.FlowStyle == 0 {
			return data, false
		}
		start, err := yamlByteOffset(data, item.Line, item.Column)
		if err != nil {
			return data, false
		}
		end, err := flowMappingEndCached(&flowDocument{data: data}, item)
		if err != nil {
			return data, false
		}
		end++
		if yamlRangeHasComment(data, start, end) {
			return data, false
		}
		switch {
		case index+1 < len(list.Content):
			next, err := yamlByteOffset(data, list.Content[index+1].Line, list.Content[index+1].Column)
			if err != nil || strings.TrimSpace(string(data[end:next])) != "," {
				return data, false
			}
			end = next
		case index > 0:
			before := start - 1
			for before >= 0 && (data[before] == ' ' || data[before] == '\t') {
				before--
			}
			if before < 0 || data[before] != ',' {
				return data, false
			}
			start = before
		}
		return append(append([]byte(nil), data[:start]...), data[end:]...), true
	}
	return data, false
}

// retractBlockNarrative removes a block entry without consuming adjacent comments.
//
// Example: An emptied sequence remains an explicit empty list.
func retractBlockNarrative(
	data []byte,
	root *yaml.Node,
	list *yaml.Node,
	item *yaml.Node,
	section string,
	index int,
) ([]byte, bool) {
	lines := strings.Split(string(data), "\n")
	start := item.Line - 1
	if start < 0 || start >= len(lines) {
		return data, false
	}
	dash := strings.Index(lines[start], "- ")
	if dash < 0 || strings.TrimSpace(lines[start][:dash]) != "" {
		return data, false
	}
	end := len(lines)
	next := nextMappingFieldLine(root, section)
	switch {
	case index+1 < len(list.Content):
		end = list.Content[index+1].Line - 1
	case next > 0:
		end = next - 1
	case end > 0 && lines[end-1] == "":
		end--
	}
	if end < start || end > len(lines) {
		return data, false
	}
	end = trimFollowingComments(lines, end, item.Line)
	startOffset, err := yamlByteOffset(data, start+1, 1)
	if err != nil {
		return data, false
	}
	endOffset := len(data)
	if end < len(lines) {
		endOffset, err = yamlByteOffset(data, end+1, 1)
		if err != nil {
			return data, false
		}
	}
	if yamlRangeHasComment(data, startOffset, endOffset) {
		return data, false
	}
	if len(list.Content) != 1 {
		return append(append([]byte(nil), data[:startOffset]...), data[endOffset:]...), true
	}
	ending := ""
	if end > start && strings.HasSuffix(lines[end-1], "\r") {
		ending = "\r"
	}
	indent := emptyNarrativeIndent(root, section, lines[start][:dash])
	replacement := []string{indent + "[]" + ending}
	result := append(append(append([]string(nil), lines[:start]...), replacement...), lines[end:]...)
	return []byte(strings.Join(result, "\n")), true
}

// emptyNarrativeIndent places an empty sequence beneath its mapping key.
//
// Example: An indentless block sequence becomes an indented flow sequence.
func emptyNarrativeIndent(
	root *yaml.Node,
	section string,
	indent string,
) string {
	for i := 0; i+1 < len(root.Content); i += 2 {
		if root.Content[i].Value == section && len(indent) < root.Content[i].Column {
			return strings.Repeat(" ", root.Content[i].Column+1)
		}
	}
	return indent
}
