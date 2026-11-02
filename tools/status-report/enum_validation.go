package main

import (
	"bytes"
	"fmt"

	"gopkg.in/yaml.v3"
)

// validateEnumNodes rejects non-scalar enum values and custom YAML tags.
//
// Example: A task status mapping is not an unknown status.
func validateEnumNodes(data []byte) error {
	var root yaml.Node
	if err := yaml.NewDecoder(bytes.NewReader(data)).Decode(&root); err != nil {
		return err
	}
	if len(root.Content) == 0 || root.Content[0].Kind != yaml.MappingNode {
		return nil
	}
	top := root.Content[0]
	for i := 0; i+1 < len(top.Content); i += 2 {
		key, value := top.Content[i].Value, top.Content[i+1]
		switch key {
		case "timeline_state":
			if err := checkEnumScalar(value, false); err != nil {
				return fmt.Errorf("timeline_state: %w", err)
			}
		case "tasks", "lanes":
			if err := validateEnumSequence(key, value); err != nil {
				return err
			}
		}
	}
	return nil
}

// validateEnumSequence checks task or lane entries without resolving aliases.
//
// Example: Reject an aliased task whose status would evade validation.
func validateEnumSequence(
	section string,
	node *yaml.Node,
) error {
	if err := rejectAliases(node); err != nil {
		return fmt.Errorf("%s: %w", section, err)
	}
	if node.Kind != yaml.SequenceNode {
		return nil
	}
	for index, item := range node.Content {
		if err := validateEnumMapping(section, index, item); err != nil {
			return err
		}
	}
	return nil
}

// validateEnumMapping checks fixed enum fields of a task or lane.
//
// Example: Reject an array used for required_environment.
func validateEnumMapping(
	section string,
	index int,
	node *yaml.Node,
) error {
	if node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		field, value := node.Content[i].Value, node.Content[i+1]
		if section == "tasks" && field == "effort" {
			if err := validateEffortEnum(index, value); err != nil {
				return err
			}
			continue
		}
		if !isEnumField(section, field) {
			continue
		}
		if err := checkEnumScalar(value, section == "tasks" && field == "status"); err != nil {
			return fmt.Errorf("%s[%d].%s: %w", section, index, field, err)
		}
	}
	return nil
}

// isEnumField identifies the schema fields with fixed wire labels.
//
// Example: A lane's test_status is an enum field.
func isEnumField(
	section string,
	field string,
) bool {
	if section == "tasks" {
		return field == "status"
	}
	switch field {
	case "implementation_status", "test_status", "prod_status", "required_environment", "root_task_status":
		return true
	default:
		return false
	}
}

// validateEffortEnum checks the kind inside a task's effort mapping.
//
// Example: Reject an array where elapsed or work is expected.
func validateEffortEnum(
	index int,
	node *yaml.Node,
) error {
	if node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == "kind" {
			if err := checkEnumScalar(node.Content[i+1], false); err != nil {
				return fmt.Errorf("tasks[%d].effort.kind: %w", index, err)
			}
		}
	}
	return nil
}

// checkEnumScalar permits strings and optionally the standard null scalar.
//
// Example: Explicit null is valid for an unknown task status only.
func checkEnumScalar(
	node *yaml.Node,
	allowNull bool,
) error {
	if node.Kind != yaml.ScalarNode || (node.Tag != "!!str" && !(allowNull && node.Tag == "!!null")) {
		return fmt.Errorf("expected string%s", nullSuffix(allowNull))
	}
	return nil
}

// nullSuffix explains when null is accepted in validation errors.
//
// Example: Task status errors include the allowed null alternative.
func nullSuffix(allow bool) string {
	if allow {
		return " or null"
	}
	return ""
}

// rejectAliases prevents merges from bypassing enum node validation.
//
// Example: Put a task status directly on its task rather than in a YAML merge.
func rejectAliases(node *yaml.Node) error {
	if node.Kind == yaml.AliasNode || node.Tag == "!!merge" {
		return fmt.Errorf("YAML aliases and merges are unsupported in tasks and lanes")
	}
	for _, child := range node.Content {
		if err := rejectAliases(child); err != nil {
			return err
		}
	}
	return nil
}
