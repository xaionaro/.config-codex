package main

import (
	"bytes"
	"fmt"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// syncTimelineSnapshot carries a complete source-supplied timeline and its anchor.
//
// Example: Replace one four-hour snapshot without rebucketing its rows.
type syncTimelineSnapshot struct {
	AsOf    string          `json:"as_of"`
	State   string          `json:"state"`
	Entries []timelineEntry `json:"entries"`
}

// applySyncTimeline replaces an entire validated timeline snapshot.
//
// Example: Publish a complete source-supplied snapshot atomically.
func applySyncTimeline(data []byte, snapshot syncTimelineSnapshot) ([]byte, bool) {
	_, err := parseUTC(snapshot.AsOf)
	if err != nil {
		return data, false
	}
	switch snapshot.State {
	case "present":
		if len(snapshot.Entries) == 0 {
			return data, false
		}
	case "verified_empty":
		if len(snapshot.Entries) != 0 {
			return data, false
		}
	default:
		return data, false
	}
	probe := report{Timestamp: snapshot.AsOf, TimelineAsOf: snapshot.AsOf, Timeline: snapshot.Entries}
	if validateTimeline(probe) != nil {
		return data, false
	}
	counts := map[string]int{}
	for _, entry := range snapshot.Entries {
		if strings.TrimSpace(entry.Fast) == "" || strings.TrimSpace(entry.Normal) == "" {
			return data, false
		}
		counts[entry.Job]++
	}
	for _, count := range counts {
		if count != int(timelineWindow/timelineInterval) {
			return data, false
		}
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return data, false
	}
	root := doc.Content[0]
	var sequence yaml.Node
	entries := snapshot.Entries
	if entries == nil {
		entries = []timelineEntry{}
	}
	if sequence.Encode(entries) != nil {
		return data, false
	}
	sequence.Style = yaml.FlowStyle
	for _, entry := range sequence.Content {
		entry.Style = yaml.FlowStyle
	}
	encoded, err := yaml.Marshal(&sequence)
	if err != nil {
		return data, false
	}
	values := map[string]string{"timeline_as_of": fmt.Sprintf("%q", snapshot.AsOf), "timeline_state": snapshot.State, "timeline": strings.TrimSpace(string(encoded))}
	lines := strings.SplitAfter(string(data), "\n")
	offsets := make([]int, len(lines)+1)
	for i, line := range lines {
		offsets[i+1] = offsets[i] + len(line)
	}
	var edits []scalarEdit
	var missing []string
	for _, key := range []string{"timeline_as_of", "timeline_state", "timeline"} {
		node := mapValue(root, key)
		replacement := key + ": " + values[key] + "\n"
		if node == nil {
			missing = append(missing, replacement)
			continue
		}
		keyLine := 0
		for i := 0; i+1 < len(root.Content); i += 2 {
			if root.Content[i].Value == key {
				keyLine = root.Content[i].Line
				break
			}
		}
		if keyLine < 1 || keyLine > len(lines) {
			return data, false
		}
		endLine := nextMappingFieldLine(root, key)
		if endLine == 0 {
			endLine = len(lines) + 1
		}
		if endLine-1 > len(lines) || endLine <= keyLine {
			return data, false
		}
		start, end := offsets[keyLine-1], offsets[endLine-1]
		if bytes.Contains(data[start:end], []byte("#")) {
			return data, false
		}
		edits = append(edits, scalarEdit{Start: reportByteOffset(start), End: reportByteOffset(end), Value: replacement})
	}
	sort.Slice(edits, func(i, j int) bool { return edits[i].Start > edits[j].Start })
	out := append([]byte(nil), data...)
	for _, edit := range edits {
		out = append(append(append([]byte(nil), out[:edit.Start]...), edit.Value...), out[edit.End:]...)
	}
	if len(missing) > 0 {
		if len(out) > 0 && out[len(out)-1] != '\n' {
			out = append(out, '\n')
		}
		out = append(out, strings.Join(missing, "")...)
	}
	if _, err := parse(out); err != nil {
		return data, false
	}
	return out, true
}
