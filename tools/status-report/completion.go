package main

import (
	"fmt"
	"strings"
)

// renderCompletionEstimates reports supplied projections without adding parallel durations.
//
// Example: Display each priority and overall completion range.
func renderCompletionEstimates(
	b *strings.Builder,
	r report,
) {
	estimates := map[string]completionEstimate{}
	for _, e := range r.PriorityEstimates {
		estimates[e.Priority] = e
	}
	seen := map[string]bool{}
	fmt.Fprintln(b, "\nCompletion estimates:")
	for _, t := range r.Tasks {
		if seen[t.Priority] {
			continue
		}
		seen[t.Priority] = true
		e, ok := estimates[t.Priority]
		if !ok {
			fmt.Fprintf(b, "Priority %s completion estimate: unknown\n", t.Priority)
			continue
		}
		writeCompletionEstimate(b, "Priority "+t.Priority+" completion estimate", e)
	}
	if r.CompletionEstimate == nil {
		fmt.Fprintln(b, "Overall completion estimate: unknown")
	} else {
		writeCompletionEstimate(b, "Overall completion estimate", *r.CompletionEstimate)
	}
}

// writeCompletionEstimate renders one supplied range and its limitations.
//
// Example: Show a range together with its assumptions.
func writeCompletionEstimate(
	b *strings.Builder,
	label string,
	e completionEstimate,
) {
	fmt.Fprintf(b, "%s: %g–%g minutes elapsed; endpoint %s–%s; basis: %s; assumptions: %s; dependencies: %s; critical path: %s\n", label, *e.MinMinutes, *e.MaxMinutes, e.Earliest, e.Latest, e.Basis, e.Assumptions, e.Dependencies, e.CriticalPath)
}
