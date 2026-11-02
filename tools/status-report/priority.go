package main

import (
	"fmt"
	"slices"
	"strings"
)

// validatePriorityOrder validates the legacy forecast grouping order.
//
// Example: Unknown labels cannot be assigned a rank.
func validatePriorityOrder(order []priorityLabel) error {
	seen := map[priorityLabel]bool{}
	for _, label := range order {
		trimmed := strings.TrimSpace(string(label))
		if trimmed == "" || strings.EqualFold(trimmed, "unknown") || seen[label] {
			return fmt.Errorf("priority_order requires unique nonblank ranked labels other than unknown")
		}
		seen[label] = true
	}
	return nil
}

// priorityScore computes comparable impact per remaining work minute or explains why it cannot.
//
// Example: Nine points over thirty work minutes yields 0.3.
func priorityScore(t task, scale string) (float64, string) {
	switch {
	case strings.TrimSpace(scale) == "":
		return 0, "missing impact scale"
	case t.ImpactPoints == nil:
		return 0, "missing impact points"
	case strings.TrimSpace(t.ImpactBasis) == "":
		return 0, "missing impact basis"
	case t.Effort.Kind != effortWork:
		return 0, "effort is not work minutes"
	case t.Effort.MaxMinutes == nil || *t.Effort.MaxMinutes <= 0:
		return 0, "remaining effort must be positive"
	}
	return *t.ImpactPoints / float64(*t.Effort.MaxMinutes), ""
}

// priorityText displays a calculated score or its missing input.
//
// Example: A scored task displays points per work-minute.
func priorityText(t task, scale string) string {
	score, reason := priorityScore(t, scale)
	if reason != "" {
		return "unscored: " + reason
	}
	return fmt.Sprintf("%g points/work-minute (%g points; %s; scale: %s)", score, *t.ImpactPoints, t.ImpactBasis, scale)
}

// orderTaskIDs sorts scored positions while preserving unscored positions and ties.
//
// Example: Low, unscored, high becomes high, unscored, low.
func orderTaskIDs(ids []taskID, tasks map[taskID]task, scale string) []taskID {
	result := slices.Clone(ids)
	scored := make([]taskID, 0, len(ids))
	for _, id := range ids {
		if _, reason := priorityScore(tasks[id], scale); reason == "" {
			scored = append(scored, id)
		}
	}
	slices.SortStableFunc(scored, func(a, b taskID) int {
		x, _ := priorityScore(tasks[a], scale)
		y, _ := priorityScore(tasks[b], scale)
		switch {
		case x > y:
			return -1
		case x < y:
			return 1
		default:
			return 0
		}
	})
	next := 0
	for i, id := range result {
		if _, reason := priorityScore(tasks[id], scale); reason == "" {
			result[i] = scored[next]
			next++
		}
	}
	return result
}
