package main

import (
	"fmt"
	"strconv"

	"gopkg.in/yaml.v3"
)

// appendReportField inserts a missing field in a block or flow report mapping.
//
// Example: Add sync metadata inside a JSON-root report without rewriting its fields.
func appendReportField(
	data []byte,
	key string,
	value string,
) ([]byte, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	if len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("report is not a mapping")
	}
	root := doc.Content[0]
	if mapValue(root, key) != nil {
		return nil, fmt.Errorf("report field %s already exists", key)
	}
	if root.Style&yaml.FlowStyle != 0 {
		end, err := flowMappingEndCached(&flowDocument{data: data}, root)
		if err != nil {
			return nil, err
		}
		sep := ""
		if len(root.Content) > 0 {
			sep = ", "
			last := end - 1
			for last >= 0 && (data[last] == ' ' || data[last] == '\t' || data[last] == '\n' || data[last] == '\r') {
				last--
			}
			if last >= 0 && data[last] == ',' {
				sep = " "
			}
		}
		insert := sep + strconv.Quote(key) + ": " + value
		return append(append(append([]byte(nil), data[:end]...), []byte(insert)...), data[end:]...), nil
	}
	suffix := key + ": " + value + "\n"
	if len(data) > 0 && data[len(data)-1] != '\n' {
		suffix = "\n" + suffix
	}
	return append(append([]byte(nil), data...), []byte(suffix)...), nil
}
