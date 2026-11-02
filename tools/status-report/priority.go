package main

import (
	"fmt"
	"slices"
	"strings"
)

// prioritySorter compares task IDs by an explicitly supplied ranking.
//
// Example: A high-ranked task precedes a low-ranked task.
type prioritySorter struct {
	Ranks map[priorityLabel]int
	Tasks map[taskID]task
}

// compare returns the ordering of two ranked task IDs.
//
// Example: Equal ranks preserve their input order.
func (s prioritySorter) compare(
	a,
	b taskID,
) int {
	return s.Ranks[s.Tasks[a].Priority] - s.Ranks[s.Tasks[b].Priority]
}

// validatePriorityOrder rejects ambiguous priority ranking entries.
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

// priorityRanks translates explicit ordering into sortable indices.
//
// Example: The first listed label receives the highest rank.
func priorityRanks(order []priorityLabel) map[priorityLabel]int {
	ranks := map[priorityLabel]int{}
	for i, label := range order {
		ranks[label] = i
	}
	return ranks
}

// orderTaskIDs sorts ranked slots while preserving unranked positions.
//
// Example: Low, unknown, high becomes high, unknown, low.
func orderTaskIDs(
	ids []taskID,
	tasks map[taskID]task,
	order []priorityLabel,
) []taskID {
	ranks := priorityRanks(order)
	ranked := make([]taskID, 0, len(ids))
	result := slices.Clone(ids)
	for _, id := range ids {
		if _, ok := ranks[tasks[id].Priority]; ok {
			ranked = append(ranked, id)
		}
	}
	sorter := prioritySorter{Ranks: ranks, Tasks: tasks}
	slices.SortStableFunc(ranked, sorter.compare)
	next := 0
	for i, id := range result {
		if _, ok := ranks[tasks[id].Priority]; ok {
			result[i] = ranked[next]
			next++
		}
	}
	return result
}

// rankingIncomplete reports when some task labels lack a supported rank.
//
// Example: Unknown priority is always disclosed as unranked.
func rankingIncomplete(
	tasks []task,
	order []priorityLabel,
) bool {
	ranks := priorityRanks(order)
	if len(order) == 0 {
		return true
	}
	for _, t := range tasks {
		if _, ok := ranks[t.Priority]; !ok {
			return true
		}
	}
	return false
}
