package main

import (
	"bytes"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// estimate describes the remaining work range and its basis.
//
// Example: Record a 20–30 minute elapsed package.
type estimate struct {
	MinMinutes *float64   `yaml:"min_minutes"`
	MaxMinutes *float64   `yaml:"max_minutes"`
	Kind       effortKind `yaml:"kind"`
	Basis      string     `yaml:"basis"`
}

// queueReview records the scoped review of one newly estimated queue item.
//
// Example: Record a critic check for a newly queued item.
type queueReview struct {
	TaskID     string `yaml:"task_id"`
	Reporter   string `yaml:"reporter"`
	Critic     string `yaml:"critic"`
	Rounds     int    `yaml:"rounds"`
	Estimate   string `yaml:"estimate"`
	Impact     string `yaml:"impact"`
	Priority   string `yaml:"priority"`
	Unresolved string `yaml:"unresolved"`
}

// task records one node of the package hierarchy.
//
// Example: Represent one leaf package or its parent.
type task struct {
	ID                string     `yaml:"id"`
	ParentID          string     `yaml:"parent_id"`
	Title             string     `yaml:"title"`
	Owner             string     `yaml:"owner"`
	Context           string     `yaml:"context"`
	Priority          string     `yaml:"priority"`
	Impact            string     `yaml:"impact"`
	Effort            estimate   `yaml:"effort"`
	Status            workStatus `yaml:"status"`
	Evidence          string     `yaml:"evidence"`
	IndivisibleReason string     `yaml:"indivisible_reason"`
}

// report holds one persisted status projection.
//
// Example: Load the current status projection from YAML.
type report struct {
	Timestamp          string               `yaml:"timestamp"`
	State              string               `yaml:"state"`
	Progress           []string             `yaml:"progress"`
	Decisions          []any                `yaml:"decisions"`
	Blockers           []string             `yaml:"blockers_risks"`
	Verification       []string             `yaml:"verification"`
	NextFocus          string               `yaml:"next_focus"`
	ScopeComplete      *bool                `yaml:"scope_complete"`
	Tasks              []task               `yaml:"tasks"`
	TopPriorities      []string             `yaml:"top_priorities"`
	Lanes              []lane               `yaml:"lanes"`
	RootForecasts      []forecast           `yaml:"root_forecasts"`
	Roster             map[string]any       `yaml:"roster"`
	Timeline           []timelineEntry      `yaml:"timeline"`
	TimelineState      timelineState        `yaml:"timeline_state"`
	Reviews            []queueReview        `yaml:"reviews"`
	Details            map[string]any       `yaml:"details"`
	PriorityEstimates  []completionEstimate `yaml:"priority_estimates"`
	CompletionEstimate *completionEstimate  `yaml:"completion_estimate"`
}

// parse decodes and validates one structured status projection.
//
// Example: Reject a report with a missing task reference.
func parse(data []byte) (report, error) {
	var r report
	d := yaml.NewDecoder(bytes.NewReader(data))
	d.KnownFields(true)
	if err := d.Decode(&r); err != nil {
		return r, fmt.Errorf("invalid YAML/schema: %w", err)
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return r, fmt.Errorf("expected one YAML document")
	}
	if _, err := parseUTC(r.Timestamp); err != nil {
		return r, fmt.Errorf("timestamp must be RFC3339 UTC")
	}
	if strings.TrimSpace(r.State) == "" || strings.TrimSpace(r.NextFocus) == "" || r.ScopeComplete == nil {
		return r, fmt.Errorf("state, next_focus and scope_complete are required")
	}
	if r.Progress == nil || r.Decisions == nil || r.Blockers == nil || r.Verification == nil || r.Tasks == nil || r.TopPriorities == nil {
		return r, fmt.Errorf("progress, decisions, blockers_risks, verification, tasks and top_priorities must be lists")
	}
	if r.TimelineState == timelineVerifiedEmpty && len(r.Timeline) > 0 {
		return r, fmt.Errorf("verified_empty timeline cannot contain entries")
	}
	if r.TimelineState == timelinePresent && len(r.Timeline) == 0 {
		return r, fmt.Errorf("present timeline requires entries")
	}
	byID := map[string]task{}
	children := map[string]int{}
	for _, t := range r.Tasks {
		if t.ID == "" || t.Title == "" || t.Priority == "" || t.Impact == "" || t.Effort.MinMinutes == nil || t.Effort.MaxMinutes == nil || math.IsNaN(*t.Effort.MinMinutes) || math.IsNaN(*t.Effort.MaxMinutes) || math.IsInf(*t.Effort.MinMinutes, 0) || math.IsInf(*t.Effort.MaxMinutes, 0) || *t.Effort.MinMinutes < 0 || *t.Effort.MaxMinutes < *t.Effort.MinMinutes || t.Effort.Kind == effortUnknown || strings.TrimSpace(t.Effort.Basis) == "" {
			return r, fmt.Errorf("task requires id, title, priority, impact and effort")
		}
		if _, exists := byID[t.ID]; exists {
			return r, fmt.Errorf("duplicate task id %q", t.ID)
		}
		byID[t.ID] = t

		if t.Status == statusClosed && strings.TrimSpace(t.Evidence) == "" {
			return r, fmt.Errorf("task %s: CLOSED requires acceptance evidence", t.ID)
		}
	}
	for _, t := range r.Tasks {
		if t.ParentID != "" {
			if _, ok := byID[t.ParentID]; !ok {
				return r, fmt.Errorf("task %s: missing parent %s", t.ID, t.ParentID)
			}
			children[t.ParentID]++
		}
		seen := map[string]bool{}
		for id := t.ID; id != ""; id = byID[id].ParentID {
			if seen[id] {
				return r, fmt.Errorf("task cycle at %s", id)
			}
			seen[id] = true
			if _, ok := byID[id]; !ok {
				break
			}
		}
	}
	for _, t := range r.Tasks {
		if children[t.ID] == 0 && *t.Effort.MaxMinutes > 30 && strings.TrimSpace(t.IndivisibleReason) == "" {
			return r, fmt.Errorf("task %s: leaf longer than 30 minutes needs indivisible_reason", t.ID)
		}
	}
	seenTop := map[string]bool{}
	for _, id := range r.TopPriorities {
		if _, ok := byID[id]; !ok {
			return r, fmt.Errorf("unknown top priority task %s", id)
		}
		if seenTop[id] {
			return r, fmt.Errorf("duplicate top priority %s", id)
		}
		seenTop[id] = true
	}
	for _, review := range r.Reviews {
		if _, ok := byID[review.TaskID]; !ok {
			return r, fmt.Errorf("review references unknown task %s", review.TaskID)
		}
		if review.Reporter == "" || review.Critic == "" || review.Rounds < 1 || review.Rounds > 5 || review.Estimate == "" || review.Impact == "" || review.Priority == "" || review.Unresolved == "" {
			return r, fmt.Errorf("review for %s requires reporter, critic, 1–5 rounds, estimate, impact, priority and unresolved", review.TaskID)
		}
	}
	if err := validateSections(r); err != nil {
		return r, err
	}
	return r, nil
}

// render derives a readable status report from a validated projection.
//
// Example: Produce a human-readable report and derived progress bar.
func render(r report) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Status (%s)\n%s\n\n", r.Timestamp, r.State)
	writeList(&b, "Progress updates", r.Progress)
	fmt.Fprintln(&b, "Decisions:")
	for _, v := range r.Decisions {
		writeValue(&b, v, 1)
	}
	b.WriteString("\n")
	writeList(&b, "Blockers / risks", r.Blockers)
	writeList(&b, "Verification", r.Verification)
	fmt.Fprintf(&b, "Next focus: %s\n\n", r.NextFocus)
	byID := map[string]task{}
	children := map[string][]string{}
	for _, t := range r.Tasks {
		byID[t.ID] = t
		children[t.ParentID] = append(children[t.ParentID], t.ID)
	}
	fmt.Fprintln(&b, "Top priorities:")
	if len(r.TopPriorities) == 0 {
		fmt.Fprintln(&b, "- unknown / none identified")
	}
	for _, id := range r.TopPriorities {
		writeTaskLine(&b, byID[id], "")
	}
	fmt.Fprintln(&b, "\nFull task tree:")
	writeTaskTree(&b, byID, children, "", 0)
	known, done, unknownCount := 0, 0, 0
	var unscored, covered, oversized []string
	for _, t := range r.Tasks {
		if len(children[t.ID]) > 0 {
			continue
		}
		if *t.Effort.MaxMinutes > 30 {
			oversized = append(oversized, t.ID+": "+t.IndivisibleReason)
		}
		if t.Status == statusUnknown {
			unknownCount++
			unscored = append(unscored, t.ID)
			continue
		}
		covered = append(covered, t.ID)
		known++
		if t.Status == statusClosed {
			done++
		}
	}
	if known == 0 {
		fmt.Fprintf(&b, "\nProgress: unknown (no scored leaf packages; equal-package estimate from half-hour breakdown; partial coverage; unscored: %s; scope complete: %t)\n", strings.Join(unscored, ", "), *r.ScopeComplete)
	} else {
		pct := done * 100 / known
		filled := done * 20 / known
		partial := unknownCount > 0 || !*r.ScopeComplete
		qualifier := ""
		if partial {
			qualifier = "; partial coverage"
		}
		fmt.Fprintf(&b, "\nProgress: [%s%s] %d%% (%d/%d known leaf tasks; equal-package estimate from half-hour breakdown%s; covered: %s; unscored: %s; scope complete: %t)\n", strings.Repeat("#", filled), strings.Repeat("-", 20-filled), pct, done, known, qualifier, strings.Join(covered, ", "), strings.Join(unscored, ", "), *r.ScopeComplete)
	}
	if len(oversized) > 0 {
		fmt.Fprintf(&b, "Larger indivisible packages: %s\n", strings.Join(oversized, "; "))
	}
	renderCompletionEstimates(&b, r)
	renderLaneTable(&b, r.Lanes, byID)
	for _, lane := range r.Lanes {
		renderForecast(&b, lane)
	}
	for _, f := range r.RootForecasts {
		renderRootForecast(&b, f)
	}
	for _, section := range []struct {
		name  string
		value any
	}{{"Roster", r.Roster}, {"Details", r.Details}} {
		fmt.Fprintf(&b, "\n%s:\n", section.name)
		writeValue(&b, section.value, 0)
	}
	if r.TimelineState == timelineVerifiedEmpty {
		fmt.Fprintln(&b, "\nTimeline: verified no evidenced activity.")
	} else {
		fmt.Fprintln(&b, "\nTimeline:")
		if r.TimelineState == timelineUnavailable || (r.TimelineState == timelineUnknown && len(r.Timeline) > 0) {
			fmt.Fprintln(&b, "History is incomplete or unavailable; displayed rows do not establish full coverage.")
		}
		writeTimeline(&b, r.Timeline)
	}
	fmt.Fprintln(&b, "\nQueue item reviews:")
	for _, v := range r.Reviews {
		fmt.Fprintf(&b, "- task %s | reporter: %s | critic: %s | rounds: %d | estimate: %s | impact: %s | priority: %s | unresolved: %s\n", v.TaskID, v.Reporter, v.Critic, v.Rounds, v.Estimate, v.Impact, v.Priority, v.Unresolved)
	}
	return b.String()
}

// unknown supplies a readable label for absent values.
//
// Example: Show unknown when a field is empty.
func unknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// writeValue renders extensible nested report details.
//
// Example: Show nested extension details without dropping fields.
func writeValue(
	b *strings.Builder,
	v any,
	depth int,
) {
	pad := strings.Repeat("  ", depth)
	switch x := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			switch x[k].(type) {
			case map[string]any, []any:
				fmt.Fprintf(b, "%s%s:\n", pad, k)
				writeValue(b, x[k], depth+1)
			default:
				fmt.Fprintf(b, "%s%s: %v\n", pad, k, x[k])
			}
		}
	case []any:
		for _, item := range x {
			switch item.(type) {
			case map[string]any, []any:
				fmt.Fprintf(b, "%s-\n", pad)
				writeValue(b, item, depth+1)
			default:
				fmt.Fprintf(b, "%s- %v\n", pad, item)
			}
		}
	case []map[string]any:
		for _, item := range x {
			fmt.Fprintf(b, "%s-\n", pad)
			writeValue(b, item, depth+1)
		}
	default:
		fmt.Fprintf(b, "%s%v\n", pad, v)
	}
}

// main routes validation and rendering from a file or stdin.
//
// Example: Run validate on a YAML file from the command line.
func main() {
	if len(os.Args) < 2 || len(os.Args) > 3 || (os.Args[1] != "validate" && os.Args[1] != "render") {
		fmt.Fprintln(os.Stderr, "usage: status-report validate|render [FILE] (default: stdin)")
		os.Exit(2)
	}
	var data []byte
	var err error
	if len(os.Args) == 3 && os.Args[2] != "-" {
		data, err = os.ReadFile(os.Args[2])
	} else {
		data, err = io.ReadAll(os.Stdin)
	}
	if err == nil {
		var r report
		r, err = parse(data)
		if err == nil {
			if os.Args[1] == "validate" {
				fmt.Println("Schema valid (does not verify factual truth or reviewer independence).")
			} else {
				fmt.Print(render(r))
			}
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "status-report:", err)
		os.Exit(1)
	}
}

// renderForecast projects the supplied forecast; it does not estimate deadlines.
//
// Example: Print the canonical lane deadline from its projection.
func renderForecast(
	b *strings.Builder,
	l lane,
) {
	if l.NextMilestone != "" {
		fmt.Fprintf(b, "\nNext milestone: %s\n", l.NextMilestone)
	}
	if l.CompletedAt != "" {
		fmt.Fprintf(b, "Completed: %s; no active forecast deadline.\n", l.CompletedAt)
		return
	}
	if l.Forecast == nil {
		return
	}
	f := *l.Forecast
	switch {
	case f.Target == "unknown":
		fmt.Fprintf(b, "Forecast deadline: %s — unknown.\n", f.Outcome)
	case f.Target != "":
		fmt.Fprintf(b, "Forecast deadline: %s will be finished by %s.\n", f.Outcome, f.Target)
	}
	renderForecastDetails(b, f)
	renderScenarios(b, f.Outcome, f)
}

// writeList displays the supplied status items.
//
// Example: Print the report verification items.
func writeList(
	b *strings.Builder,
	title string,
	values []string,
) {
	fmt.Fprintf(b, "%s:\n", title)
	for _, v := range values {
		fmt.Fprintf(b, "- %s\n", v)
	}
	b.WriteByte('\n')
}

// writeTaskLine displays a task once in a requested list.
//
// Example: Print one task in the priority list.
func writeTaskLine(
	b *strings.Builder,
	t task,
	indent string,
) {
	fmt.Fprintf(b, "%s- %s %s | priority: %s | impact: %s | effort: %g–%g minutes %s (%s) | status: %s", indent, t.ID, t.Title, t.Priority, t.Impact, *t.Effort.MinMinutes, *t.Effort.MaxMinutes, t.Effort.Kind, t.Effort.Basis, t.Status.String())
	if t.Owner != "" {
		fmt.Fprintf(b, " | owner: %s", t.Owner)
	} else {
		fmt.Fprint(b, " | owner: unowned")
	}
	if t.Context != "" {
		fmt.Fprintf(b, " | context: %s", t.Context)
	}
	if t.Evidence != "" {
		fmt.Fprintf(b, " | evidence: %s", t.Evidence)
	}
	if t.IndivisibleReason != "" {
		fmt.Fprintf(b, " | indivisible: %s", t.IndivisibleReason)
	}
	b.WriteByte('\n')
}

// writeTaskTree renders parent and child tasks in input order.
//
// Example: Print child packages beneath their parent.
func writeTaskTree(
	b *strings.Builder,
	byID map[string]task,
	children map[string][]string,
	parent string,
	depth int,
) {
	for _, id := range children[parent] {
		writeTaskLine(b, byID[id], strings.Repeat("  ", depth))
		writeTaskTree(b, byID, children, id, depth+1)
	}
}
