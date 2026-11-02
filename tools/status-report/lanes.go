package main

import (
	"fmt"
	"strings"
)

// renderLaneTable displays readiness and task context without combining statuses.
func renderLaneTable(b *strings.Builder, lanes []map[string]any, tasks map[string]task) {
	if len(lanes) == 0 {
		return
	}
	fmt.Fprintln(b, "\n| Task ID | Parent ID | Lane | Lane requirement context | Priority | Impact | Effort | Stage | Owner | Implementation Status | Test Status | Prod Status | Blocker | Next milestone | Forecast deadline / recalibration | Dependencies / critical path | Next proof/action |")
	fmt.Fprintln(b, "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	for _, l := range lanes {
		id, _ := l["task_id"].(string)
		t := tasks[id]
		f, _ := l["forecast"].(map[string]any)
		effort := fmt.Sprintf("%g–%g minutes %s (%s)", *t.Effort.MinMinutes, *t.Effort.MaxMinutes, t.Effort.Kind, t.Effort.Basis)
		vals := []any{id, t.ParentID, l["outcome"], l["context"], t.Priority, t.Impact, effort, l["stage"], l["owner"], l["implementation_status"], l["test_status"], l["prod_status"], l["blocker"], l["next_milestone"], f["target"], f["dependencies"], l["next_action"]}
		fmt.Fprint(b, "|")
		for _, v := range vals {
			fmt.Fprintf(b, " %s |", timelineCell(v))
		}
		fmt.Fprintln(b)
	}
	for _, l := range lanes {
		if status, ok := l["root_task_status"].(string); ok && status != "" {
			fmt.Fprintf(b, "\nRoot-task status [%s / %s]: %s\n", timelineCell(l["task_id"]), timelineCell(l["outcome"]), status)
		}
	}
}

// renderScenarios displays supplied scenario facts in the required table.
func renderScenarios(b *strings.Builder, name string, f map[string]any) {
	rows, ok := f["scenarios"].([]any)
	if !ok || len(rows) == 0 {
		return
	}
	fmt.Fprintln(b, "\n| Lane/root and case | Trigger/evidence | Affected work/dependency | Added duration/range and basis | Evidence assessed; assumptions/limits | Endpoint/range | Evidence gap / next fact-finding action |")
	fmt.Fprintln(b, "| --- | --- | --- | --- | --- | --- | --- |")
	for _, v := range rows {
		row := v.(map[string]any)
		fmt.Fprintf(b, "| %s — %s | %s | %s | %s | %s | %s | %s |\n", timelineCell(name), timelineCell(row["case"]), timelineCell(row["trigger"]), timelineCell(row["affected_work"]), timelineCell(row["duration_basis"]), timelineCell(row["evidence_assumptions"]), timelineCell(row["endpoint"]), timelineCell(row["evidence_gap_next_action"]))
	}
}

// renderRootForecast prints the canonical root projection and scenarios.
func renderRootForecast(b *strings.Builder, f map[string]any) {
	outcome, _ := f["outcome"].(string)
	target, _ := f["target"].(string)
	if outcome != "" && target != "" {
		fmt.Fprintf(b, "\nRoot completion forecast: %s will be finished by %s.\n", outcome, target)
	}
	if assessment, ok := f["assessment"].(string); ok && assessment != "" {
		fmt.Fprintf(b, "Forecast assessment: %s\n", assessment)
	}
	if prior, ok := f["prior"].(string); ok && prior != "" {
		fmt.Fprintf(b, "Forecast recalibration: %s → %s; why moved: %s; supporting evidence: %s.\n", prior, target, timelineCell(f["reason"]), timelineCell(f["evidence"]))
	} else if baseline, ok := f["baseline"].(string); ok && baseline != "" {
		fmt.Fprintf(b, "Forecast recalibration: unchanged — baseline %s; supporting evidence: %s.\n", baseline, timelineCell(f["evidence"]))
	}
	if dependency, ok := f["dependencies"].(string); ok && dependency != "" {
		fmt.Fprintf(b, "Dependencies / critical path: %s\n", dependency)
	}
	renderScenarios(b, outcome, f)
}
