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
	taskWorks     map[taskID]map[workID]bool
}

// buildTaskWorkIndex resolves inherited task scope without linking siblings.
//
// Example: buildTaskWorkIndex resolves inherited task scope without linking siblings.
func buildTaskWorkIndex(
	tasks []task,
	works map[string]sourceRecord,
) taskWorkIndex {
	index := taskWorkIndex{covered: map[workID]bool{}, remaining: map[workID]bool{}, priorityWorks: map[priorityLabel]map[workID]bool{}, works: works, taskPriority: map[taskID]priorityLabel{}, taskWorks: map[taskID]map[workID]bool{}}
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
	if i.taskWorks[ancestor.ID] == nil {
		i.taskWorks[ancestor.ID] = map[workID]bool{}
	}
	i.taskWorks[ancestor.ID][id] = true
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
		if l.requiredStatus() != statusClosed && l.Lifecycle != "cancelled" && forecastApplicable(i.works[string(id)], reportingRoleLane, true) && i.taskPriority[l.TaskID] == priority {
			return true
		}
	}
	return false
}

// openWork identifies canonical work with remaining action.
//
// Example: openWork identifies canonical work with remaining action.
func openWork(state workState) bool { return state == workStateActive || state == workStateBlocked }

// forecastApplicable uses declared roles and representation to select an active forecast.
//
// Example: forecastApplicable uses declared roles and representation to select an active forecast.
func forecastApplicable(
	record sourceRecord,
	role reportingRole,
	laneRepresented bool,
) bool {
	if record.Type != "work" || !openWork(record.Data.State) || !hasRole(record.Data.Roles, role) {
		return false
	}
	return role != reportingRoleRoot || !laneRepresented
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

// workHasOutcome verifies a completion against explicitly linked outcome records.
//
// Example: Match a root completion to its ledger outcome.
func workHasOutcome(
	work sourceRecord,
	outcome string,
	records map[string]sourceRecord,
) bool {
	for _, id := range work.OutcomeRefs {
		record := records[id]
		if record.Type == "outcome" && record.Outcome == outcome {
			return true
		}
	}
	return false
}

// containsWork checks inherited or aggregate work scope for a task.
//
// Example: A lane task may inherit a work reference from its parent.
func (i taskWorkIndex) containsWork(
	task taskID,
	work workID,
) bool {
	for owner, refs := range i.taskWorks {
		if !refs[work] {
			continue
		}
		if task == owner || strings.HasPrefix(string(task), string(owner)+".") || strings.HasPrefix(string(owner), string(task)+".") {
			return true
		}
	}
	return false
}
