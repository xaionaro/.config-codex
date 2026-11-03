package main

import (
	"bytes"
	"encoding/json"
	"strings"

	"gopkg.in/yaml.v3"
)

// applySyncAddition inserts a complete task or review without altering existing records.
//
// Example: A supplied task with a unique ID is appended to the task list.
func applySyncAddition(data []byte, addition syncAddition) ([]byte, bool) {
	var record map[string]json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(addition.Record))
	if decoder.Decode(&record) != nil || len(record) == 0 {
		return data, false
	}
	var section, identity string
	var required []string
	switch addition.Target {
	case "task":
		section, identity = "tasks", "id"
		required = []string{"id", "title", "priority", "impact", "effort", "status"}
	case "review":
		section, identity = "reviews", "task_id"
		required = []string{"task_id", "reporter", "critic", "rounds", "estimate", "impact", "priority", "unresolved"}
	default:
		return data, false
	}
	for _, field := range required {
		value, exists := record[field]
		if !exists || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return data, false
		}
		if field != "effort" && field != "rounds" {
			var text string
			if json.Unmarshal(value, &text) != nil || strings.TrimSpace(text) == "" {
				return data, false
			}
		}
	}
	var id string
	if json.Unmarshal(record[identity], &id) != nil {
		return data, false
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return data, false
	}
	root := doc.Content[0]
	list := mapValue(root, section)
	if list == nil && section == "reviews" {
		entry, err := json.Marshal(record)
		if err != nil {
			return data, false
		}
		separator := ""
		if len(data) > 0 && data[len(data)-1] != '\n' {
			separator = "\n"
		}
		candidate := append(append([]byte(nil), data...), []byte(separator+"reviews: ["+string(entry)+"]\n")...)
		if _, err := parse(candidate); err != nil {
			return data, false
		}
		return candidate, true
	}
	if list == nil || list.Kind != yaml.SequenceNode {
		return data, false
	}
	for _, item := range list.Content {
		if existing := mapValue(item, identity); existing != nil && existing.Value == id {
			return data, false
		}
	}
	entry, err := json.Marshal(record)
	if err != nil {
		return data, false
	}
	candidate, ok := appendNarrativeEntry(data, root, list, section, string(entry))
	if !ok {
		return data, false
	}
	if _, err := parse(candidate); err != nil {
		return data, false
	}
	return candidate, true
}
