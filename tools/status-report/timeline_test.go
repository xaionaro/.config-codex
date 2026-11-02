package main

import (
	"strings"
	"testing"
)

// TestWriteTimeline checks that each Job retains its parent chain and path columns.
//
// Example: Two Jobs with different histories render as separate tables.
func TestWriteTimeline(t *testing.T) {
	entries := []map[string]any{
		{"job": "1.1", "parent_chain": "1 → 1.1", "interval": "15:00–15:30 UTC", "fast": "checkpoint", "normal": "unknown"},
		{"job": "1.2", "parent_chain": "1 → 1.2", "interval": "15:30–16:00 UTC", "fast": "—", "normal": "review"},
	}
	var b strings.Builder
	writeTimeline(&b, entries)
	got := b.String()
	for _, want := range []string{"1 → 1.1", "1 → 1.2", "| UTC interval | Fast | Normal |", "| 15:00–15:30 UTC | checkpoint | unknown |", "| 15:30–16:00 UTC | — | review |"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in %q", want, got)
		}
	}
}

// TestWriteTimelineUnknown checks missing evidence is not presented as empty history.
//
// Example: An omitted Fast history renders as unknown.
func TestWriteTimelineUnknown(t *testing.T) {
	var b strings.Builder
	writeTimeline(&b, []map[string]any{{"job": "1", "interval": "15:00–15:30 UTC"}})
	if !strings.Contains(b.String(), "| 15:00–15:30 UTC | unknown | unknown |") {
		t.Fatal(b.String())
	}
}

// TestWriteTimelineExtraEvidence checks that row context survives rendering.
//
// Example: Uncertain attribution and its evidence appear beside their interval.
func TestWriteTimelineExtraEvidence(t *testing.T) {
	var b strings.Builder
	writeTimeline(&b, []map[string]any{{"job": "1", "parent_chain": "1", "interval": "15:00–15:30 UTC", "fast": "checkpoint", "normal": "unknown", "evidence": "log entry", "uncertainty": "path uncertain"}})
	for _, want := range []string{"log entry", "path uncertain"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("missing %q in %q", want, b.String())
		}
	}
}
