package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestTaskAdditionOwnershipPreservesSuppliedAndAbsentValues checks replay baselines.
//
// Example: A later update detects edits to a newly added task's owner and effort.
func TestTaskAdditionOwnershipPreservesSuppliedAndAbsentValues(t *testing.T) {
	record := json.RawMessage(`{"id":"1.2","title":"Unknown","priority":"unknown","impact":"unknown","effort":{"kind":"elapsed","max_minutes":30,"min_minutes":10,"basis":"educated guess"},"status":"unknown","owner":"Alice"}`)
	values, ok := taskAdditionOwnership(record)
	require.True(t, ok)
	require.Equal(t, "Alice", values["owner"])
	require.Equal(t, `{"basis":"educated guess","kind":"elapsed","max_minutes":30,"min_minutes":10}`, values["effort"])
	require.Equal(t, syncAbsentValue, values["context"])
	require.NotContains(t, values, "id")
	_, ok = taskAdditionOwnership(json.RawMessage(`{"owner":[]}`))
	require.False(t, ok)
}

// TestTaskAdditionOwnershipRejectsLaterOwnerEdit checks its use by projection.
//
// Example: A manual effort edit blocks a subsequent logged effort update.
func TestTaskAdditionOwnershipRejectsLaterOwnerEdit(t *testing.T) {
	record := json.RawMessage(`{"effort":{"min_minutes":10,"max_minutes":30,"kind":"elapsed","basis":"educated guess"}}`)
	previous, ok := taskAdditionOwnership(record)
	require.True(t, ok)
	var update syncUpdate
	require.NoError(t, json.Unmarshal([]byte(`{"target":"task","id":"1.2","values":{"effort":{"min_minutes":5,"max_minutes":15,"kind":"elapsed","basis":"measured"}}}`), &update))
	_, ok = applyStructuredSyncUpdate([]byte(valid), update, map[string]string{"effort": previous["effort"]})
	require.True(t, ok)
	edited := strings.Replace(valid, "max_minutes: 30, kind: elapsed, basis: educated guess", "max_minutes: 29, kind: elapsed, basis: educated guess", 1)
	_, ok = applyStructuredSyncUpdate([]byte(edited), update, map[string]string{"effort": previous["effort"]})
	require.False(t, ok)
}
