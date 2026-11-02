package main

import (
	"strings"
	"testing"
)

// TestWriteTimeline checks that each Job retains its parent chain and path columns.
//
// Example: Two Jobs with different histories render as separate tables.
func TestWriteTimeline(t *testing.T) {
	entries := []timelineEntry{
		{Job: "1.1", ParentChain: "1 → 1.1", Start: "15:00", End: "15:30", Fast: "checkpoint", Normal: "unknown"},
		{Job: "1.2", ParentChain: "1 → 1.2", Start: "15:30", End: "16:00", Fast: "—", Normal: "review"},
	}
	var b strings.Builder
	writeTimeline(&b, entries)
	got := b.String()
	for _, want := range []string{"1 → 1.1", "1 → 1.2", "| UTC interval | Fast | Normal |", "| 15:00 – 15:30 | checkpoint | unknown |", "| 15:30 – 16:00 | — | review |"} {
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
	writeTimeline(&b, []timelineEntry{{Job: "1", Start: "15:00", End: "15:30"}})
	if !strings.Contains(b.String(), "| 15:00 – 15:30 | unknown | unknown |") {
		t.Fatal(b.String())
	}
}

// TestWriteTimelineExtraEvidence checks that row context survives rendering.
//
// Example: Uncertain attribution and its evidence appear beside their interval.
func TestWriteTimelineExtraEvidence(t *testing.T) {
	var b strings.Builder
	writeTimeline(&b, []timelineEntry{{Job: "1", ParentChain: "1", Start: "15:00", End: "15:30", Fast: "checkpoint", Normal: "unknown", Evidence: "log entry", Uncertainty: "path uncertain"}})
	for _, want := range []string{"log entry", "path uncertain"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("missing %q in %q", want, b.String())
		}
	}
}
