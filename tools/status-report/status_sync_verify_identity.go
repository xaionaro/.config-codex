package main

import (
	"fmt"

	"gopkg.in/yaml.v3"
)

// syncIdentityStyle describes a task ID's original YAML representation.
//
// Example: An integer scalar differs from a quoted string with the same text.
type syncIdentityStyle struct {
	Kind  yaml.Kind
	Tag   string
	Value string
	Style yaml.Style
}

// verifyTaskIdentityStyles protects the original representation of existing IDs.
//
// Example: Updating another field cannot change a numeric task ID into a string.
func verifyTaskIdentityStyles(
	original []byte,
	candidate []byte,
) error {
	before, err := taskIdentityNodes(original)
	if err != nil {
		return err
	}
	after, err := taskIdentityNodes(candidate)
	if err != nil {
		return err
	}
	for id, old := range before {
		current, exists := after[id]
		if !exists {
			continue
		}
		if err := verifyTaskIdentityFields(id, old, current); err != nil {
			return err
		}
	}
	return nil
}

// verifyTaskIdentityFields compares the original YAML styles for one task.
//
// Example: A parent ID cannot be rewritten as a differently typed scalar.
func verifyTaskIdentityFields(
	id string,
	before map[string]syncIdentityStyle,
	after map[string]syncIdentityStyle,
) error {
	for field, previous := range before {
		next, exists := after[field]
		if exists && previous.Value == next.Value && previous != next {
			return fmt.Errorf("task identity %q field %s representation changed", id, field)
		}
	}
	return nil
}

// taskIdentityNodes captures lexical identity types for existing task records.
//
// Example: A YAML integer ID and a quoted string ID remain distinguishable.
func taskIdentityNodes(data []byte) (map[string]map[string]syncIdentityStyle, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	result := map[string]map[string]syncIdentityStyle{}
	if len(doc.Content) == 0 {
		return result, nil
	}
	for _, section := range []string{"tasks", "lanes", "reviews"} {
		collectSyncIdentityNodes(result, doc.Content[0], section)
	}
	return result, nil
}

// collectSyncIdentityNodes records task-keyed identity styles in one section.
//
// Example: Two lanes sharing a task stay distinct by work and environment.
func collectSyncIdentityNodes(
	result map[string]map[string]syncIdentityStyle,
	root *yaml.Node,
	section string,
) {
	list := mapValue(root, section)
	if list != nil && list.Kind == yaml.AliasNode {
		list = list.Alias
	}
	if list == nil || list.Kind != yaml.SequenceNode {
		return
	}
	for _, item := range list.Content {
		if item.Kind == yaml.AliasNode {
			item = item.Alias
		}
		field := "task_id"
		if section == "tasks" {
			field = "id"
		}
		id := mapValue(item, field)
		if id == nil || id.Kind != yaml.ScalarNode {
			continue
		}
		fields := map[string]syncIdentityStyle{field: {Kind: id.Kind, Tag: id.Tag, Value: id.Value, Style: id.Style}}
		if parent := mapValue(item, "parent_id"); section == "tasks" && parent != nil && parent.Kind == yaml.ScalarNode {
			fields["parent_id"] = syncIdentityStyle{Kind: parent.Kind, Tag: parent.Tag, Value: parent.Value, Style: parent.Style}
		}
		key := section + "\x00" + id.Value
		if section == "lanes" {
			key += "\x00" + syncNodeText(mapValue(item, "work_ref")) + "\x00" + syncNodeText(mapValue(item, "required_environment"))
		}
		result[key] = fields
	}
}

// syncNodeText reads a scalar selector without inventing a missing value.
//
// Example: A lane key includes its explicit required environment.
func syncNodeText(node *yaml.Node) string {
	if node == nil || node.Kind != yaml.ScalarNode {
		return ""
	}
	return node.Value
}

// syncVerificationIDs preserves lexical task identifiers when verifying effects.
//
// Example: Unquoted 1.10 remains distinct from unquoted 1.1.
type syncVerificationIDs struct {
	Tasks []struct {
		ID       string `yaml:"id"`
		ParentID string `yaml:"parent_id"`
	} `yaml:"tasks"`
	Lanes []struct {
		TaskID string `yaml:"task_id"`
	} `yaml:"lanes"`
	Reviews []struct {
		TaskID string `yaml:"task_id"`
	} `yaml:"reviews"`
	TopPriorities []string `yaml:"top_priorities"`
}

// decodeSyncVerificationReport keeps task IDs as the report schema interprets them.
//
// Example: YAML numeric task identifiers are compared by their original scalar text.
func decodeSyncVerificationReport(data []byte) (map[string]any, error) {
	var report map[string]any
	if err := yaml.Unmarshal(data, &report); err != nil {
		return nil, err
	}
	var ids syncVerificationIDs
	if err := yaml.Unmarshal(data, &ids); err != nil {
		return nil, err
	}
	taskIDs := make([]string, len(ids.Tasks))
	parentIDs := make([]string, len(ids.Tasks))
	for i, item := range ids.Tasks {
		taskIDs[i] = item.ID
		parentIDs[i] = item.ParentID
	}
	if err := normalizeSyncVerificationIDs(report, "tasks", "id", taskIDs); err != nil {
		return nil, err
	}
	if err := normalizeSyncVerificationIDs(report, "tasks", "parent_id", parentIDs); err != nil {
		return nil, err
	}
	laneIDs := make([]string, len(ids.Lanes))
	for i, item := range ids.Lanes {
		laneIDs[i] = item.TaskID
	}
	if err := normalizeSyncVerificationIDs(report, "lanes", "task_id", laneIDs); err != nil {
		return nil, err
	}
	reviewIDs := make([]string, len(ids.Reviews))
	for i, item := range ids.Reviews {
		reviewIDs[i] = item.TaskID
	}
	if err := normalizeSyncVerificationIDs(report, "reviews", "task_id", reviewIDs); err != nil {
		return nil, err
	}
	if err := normalizeSyncTopPriorities(report, ids.TopPriorities); err != nil {
		return nil, err
	}
	return report, nil
}

// normalizeSyncTopPriorities keeps each priority's lexical task identifier.
//
// Example: A numeric-looking 1.10 remains distinct from 1.1.
func normalizeSyncTopPriorities(
	report map[string]any,
	ids []string,
) error {
	items, ok := report["top_priorities"].([]any)
	if !ok {
		return nil
	}
	if len(items) != len(ids) {
		return fmt.Errorf("top priority identity count mismatch")
	}
	for i := range items {
		if items[i] != nil {
			items[i] = ids[i]
		}
	}
	return nil
}

// normalizeSyncVerificationIDs applies schema-decoded identifiers to one record list.
//
// Example: Numeric YAML lane task IDs become their exact lexical strings.
func normalizeSyncVerificationIDs(
	report map[string]any,
	section string,
	field string,
	ids []string,
) error {
	items, ok := report[section].([]any)
	if !ok {
		return nil
	}
	if len(items) != len(ids) {
		return fmt.Errorf("%s identity count mismatch", section)
	}
	for i, item := range items {
		record, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if value, exists := record[field]; exists && value != nil {
			record[field] = ids[i]
		}
	}
	return nil
}
