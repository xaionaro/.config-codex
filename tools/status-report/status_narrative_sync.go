package main

import (
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
	case "progress", "decisions", "blockers_risks", "verification":
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
	list := mapValue(root, u.Target)
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
		if field != "text" || previous != "" {
			return data, false
		}
		entry := "{subject_ref: " + strconv.Quote(u.ID) + ", text: " + strconv.Quote(value) + "}"
		return appendNarrativeEntry(data, root, list, u.Target, entry)
	}
	existing := mapValue(item, field)
	if existing != nil {
		if previous == "" || existing.Kind != yaml.ScalarNode || existing.Value != previous {
			return data, false
		}
	}
	if existing == nil && (previous != "" || !itemOwned) {
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
	lines = append(lines[:insert], append([]string{indent + "- " + entry}, lines[insert:]...)...)
	return []byte(strings.Join(lines, "\n")), true
}

// narrativeSyncItemOwned verifies that exactly one subject retains its managed text.
//
// Example: An owner edit prevents subsequent automatic evidence changes.
func narrativeSyncItemOwned(
	data []byte,
	u syncUpdate,
	previousText string,
) bool {
	if previousText == "" {
		return false
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return false
	}
	list := mapValue(doc.Content[0], u.Target)
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
