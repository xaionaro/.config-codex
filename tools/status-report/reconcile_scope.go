package main

import "strings"

// workID identifies one semantic work record in the canonical ledger.
//
// Example: workID identifies one semantic work record in the canonical ledger.
type workID string

// taskWorkIndex ties each leaf to the work referenced by its own ancestry.
//
// Example: taskWorkIndex ties each leaf to the work referenced by its own ancestry.
type taskWorkIndex struct {
	covered       map[workID]bool
	remaining     map[workID]bool
	priorityWorks map[priorityLabel]map[workID]bool
	works         map[string]sourceRecord
	taskPriority  map[taskID]priorityLabel
}

// buildTaskWorkIndex resolves inherited task scope without linking siblings.
//
// Example: buildTaskWorkIndex resolves inherited task scope without linking siblings.
func buildTaskWorkIndex(
	tasks []task,
	works map[string]sourceRecord,
) taskWorkIndex {
	index := taskWorkIndex{covered: map[workID]bool{}, remaining: map[workID]bool{}, priorityWorks: map[priorityLabel]map[workID]bool{}, works: works, taskPriority: map[taskID]priorityLabel{}}
	parents := map[taskID]bool{}
	for _, t := range tasks {
		index.taskPriority[t.ID] = t.Priority
		if t.ParentID != "" {
			parents[t.ParentID] = true
		}
	}
	for _, ancestor := range tasks {
		index.includeAncestor(ancestor, tasks, parents)
	}
	return index
}

// includeAncestor resolves each reference owned by a task.
//
// Example: Associate an ancestor work reference with its descendants.
func (i taskWorkIndex) includeAncestor(
	ancestor task,
	tasks []task,
	parents map[taskID]bool,
) {
	for _, ref := range ancestor.WorkRefs {
		i.includeReference(ancestor, ref, tasks, parents)
	}
}

// includeReference propagates one valid work reference to descendant leaves.
//
// Example: Propagate root work into open leaf priorities.
func (i taskWorkIndex) includeReference(
	ancestor task,
	ref string,
	tasks []task,
	parents map[taskID]bool,
) {
	if !validRef(ref, "project-understanding.yaml") {
		return
	}
	id := workID(sourceID(ref, "project-understanding.yaml"))
	if _, ok := i.works[string(id)]; !ok {
		return
	}
	i.covered[id] = true
	for _, leaf := range tasks {
		i.includeLeaf(ancestor, leaf, id, parents)
	}
}

// includeLeaf adds only a descendant leaf's unresolved work to its priority.
//
// Example: includeLeaf adds only a descendant leaf's unresolved work to its priority.
func (i taskWorkIndex) includeLeaf(
	ancestor task,
	leaf task,
	id workID,
	parents map[taskID]bool,
) {
	if parents[leaf.ID] || leaf.Status == statusClosed {
		return
	}
	if leaf.ID != ancestor.ID && !strings.HasPrefix(string(leaf.ID), string(ancestor.ID)+".") {
		return
	}
	i.remaining[id] = true
	if i.priorityWorks[leaf.Priority] == nil {
		i.priorityWorks[leaf.Priority] = map[workID]bool{}
	}
	i.priorityWorks[leaf.Priority][id] = true
}

// priorityOpen reports unresolved work in a priority, including open acceptance lanes.
//
// Example: priorityOpen reports unresolved work in a priority, including open acceptance lanes.
func (i taskWorkIndex) priorityOpen(
	priority priorityLabel,
	lanes map[string]lane,
) bool {
	for id := range i.priorityWorks[priority] {
		if openWork(i.works[string(id)].Data.State) {
			return true
		}
	}
	for id, l := range lanes {
		if l.requiredStatus() != statusClosed && l.Lifecycle != "cancelled" && forecastApplicable(i.works[string(id)], "lane", true) && i.taskPriority[l.TaskID] == priority {
			return true
		}
	}
	return false
}

// openWork identifies canonical work with remaining action.
//
// Example: openWork identifies canonical work with remaining action.
func openWork(state workState) bool { return state == "active" || state == "blocked" }

// forecastApplicable uses declared roles and representation to select an active forecast.
//
// Example: forecastApplicable uses declared roles and representation to select an active forecast.
func forecastApplicable(
	record sourceRecord,
	role string,
	laneRepresented bool,
) bool {
	if record.Type != "work" || !openWork(record.Data.State) || !hasRole(record.Data.Roles, role) {
		return false
	}
	return role != "root" || !laneRepresented
}

// laneReferencesWork tests representation by an exact canonical work reference.
//
// Example: laneReferencesWork tests representation by an exact canonical work reference.
func laneReferencesWork(
	workID string,
	refs []string,
) bool {
	for _, ref := range refs {
		if validRef(ref, "project-understanding.yaml") && sourceID(ref, "project-understanding.yaml") == workID {
			return true
		}
	}
	return false
}
