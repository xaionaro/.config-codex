package main

import (
	"fmt"
	"strings"
)

// renderLaneTable displays readiness and task context without combining statuses.
//
// Example: Show independent readiness columns for a lane.
func renderLaneTable(
	b *strings.Builder,
	lanes []lane,
	tasks map[taskID]task,
) {
	if len(lanes) == 0 {
		return
	}
	fmt.Fprintln(b, "\n| Task ID | Parent ID | Lane | Lane requirement context | Priority | Impact | Effort | Stage | Required environment | Owner | Implementation Status | Test Status | Prod Status | Blocker | Next milestone | Forecast deadline / recalibration | Dependencies / critical path | Next proof/action |")
	fmt.Fprintln(b, "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	for _, l := range lanes {
		t := tasks[l.TaskID]
		target, dependencies := "", ""
		if l.Forecast != nil {
			target = l.Forecast.Target
			dependencies = l.Forecast.Dependencies
		}
		effort := fmt.Sprintf("%g–%g minutes %s (%s)", *t.Effort.MinMinutes, *t.Effort.MaxMinutes, t.Effort.Kind, t.Effort.Basis)
		vals := []string{string(l.TaskID), string(t.ParentID), l.Outcome, l.Context, string(t.Priority), t.Impact, effort, l.Stage, l.RequiredEnvironment.String(), l.Owner, l.ImplementationStatus.String(), l.TestStatus.String(), l.ProdStatus.String(), l.Blocker, l.NextMilestone, target, dependencies, l.NextAction}
		fmt.Fprint(b, "|")
		for _, v := range vals {
			fmt.Fprintf(b, " %s |", timelineCell(v))
		}
		fmt.Fprintln(b)
	}
	for _, l := range lanes {
		if l.RootTaskStatus != rootTaskNone {
			fmt.Fprintf(b, "\nRoot-task status [%s / %s]: %s\n", timelineCell(string(l.TaskID)), timelineCell(l.Outcome), l.RootTaskStatus.String())
		}
	}
}

// renderScenarios displays supplied scenario facts in the required table.
//
// Example: Display the base case and a downside case.
func renderScenarios(
	b *strings.Builder,
	name string,
	f forecast,
) {
	if len(f.Scenarios) == 0 {
		return
	}
	fmt.Fprintln(b, "\n| Lane/root and case | Trigger/evidence | Affected work/dependency | Added duration/range and basis | Evidence assessed; assumptions/limits | Endpoint/range | Evidence gap / next fact-finding action |")
	fmt.Fprintln(b, "| --- | --- | --- | --- | --- | --- | --- |")
	for _, r := range f.Scenarios {
		fmt.Fprintf(b, "| %s — %s | %s | %s | %s | %s | %s | %s |\n", timelineCell(name), timelineCell(r.Case), timelineCell(r.Trigger), timelineCell(r.AffectedWork), timelineCell(r.DurationBasis), timelineCell(r.EvidenceAssumptions), timelineCell(r.Endpoint), timelineCell(r.EvidenceGapNextAction))
	}
}

// renderRootForecast prints the canonical root projection and scenarios.
//
// Example: Print the canonical root completion line.
func renderRootForecast(
	b *strings.Builder,
	f forecast,
) {
	switch {
	case f.Target == "unknown":
		fmt.Fprintf(b, "\nRoot completion forecast: %s — unknown.\n", f.Outcome)
	case f.Target != "":
		fmt.Fprintf(b, "\nRoot completion forecast: %s will be finished by %s.\n", f.Outcome, f.Target)
	}
	renderForecastDetails(b, f)
	renderScenarios(b, f.Outcome, f)
}

// renderForecastDetails prints the assessment and supplied recalibration.
//
// Example: Explain how an initial forecast was established.
func renderForecastDetails(
	b *strings.Builder,
	f forecast,
) {
	if f.Assessment != "" {
		fmt.Fprintf(b, "Forecast assessment: %s\n", f.Assessment)
	}
	switch {
	case f.Prior != "":
		fmt.Fprintf(b, "Forecast recalibration: %s → %s; why moved: %s; supporting evidence: %s.\n", f.Prior, f.Target, timelineCell(f.Reason), timelineCell(f.Evidence))
	case f.Baseline != "":
		fmt.Fprintf(b, "Forecast recalibration: unchanged — baseline %s; supporting evidence: %s.\n", f.Baseline, timelineCell(f.Evidence))
	}
	if f.Dependencies != "" {
		fmt.Fprintf(b, "Dependencies / critical path: %s\n", f.Dependencies)
	}
}
