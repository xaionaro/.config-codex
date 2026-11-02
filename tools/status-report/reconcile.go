package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// workState is the lifecycle state recorded in the canonical ledger.
//
// Example: workState is the lifecycle state recorded in the canonical ledger.
type workState string

// workData holds canonical work facts used for status reconciliation.
//
// Example: workData holds canonical work facts used for status reconciliation.
type workData struct {
	CompletedAt string    `yaml:"completed_at"`
	Owner       string    `yaml:"owner"`
	NextAction  string    `yaml:"next_action"`
	State       workState `yaml:"state"`
	Roles       []string  `yaml:"reporting_roles"`
	ForecastRef string    `yaml:"forecast_ref"`
}

// sourceRecord holds the relevant work and outcome fields of a ledger record.
//
// Example: sourceRecord holds the relevant work and outcome fields of a ledger record.
type sourceRecord struct {
	Outcome     string
	OutcomeRefs []string
	Type        string
	Section     string
	Data        workData
}

// UnmarshalYAML reads only fields relevant to the record type.
//
// Example: UnmarshalYAML reads only fields relevant to the record type.
func (r *sourceRecord) UnmarshalYAML(n *yaml.Node) error {
	var wire struct {
		Type    string    `yaml:"type"`
		Section string    `yaml:"section"`
		Data    yaml.Node `yaml:"data"`
		Links   struct {
			Outcomes []string `yaml:"outcomes"`
		} `yaml:"links"`
	}
	if err := n.Decode(&wire); err != nil {
		return err
	}
	r.Type, r.Section = wire.Type, wire.Section
	r.OutcomeRefs = wire.Links.Outcomes
	if wire.Type == "outcome" {
		var data struct {
			Description string `yaml:"description"`
		}
		if err := wire.Data.Decode(&data); err != nil {
			return err
		}
		r.Outcome = data.Description
	}
	if wire.Type == "work" {
		return wire.Data.Decode(&r.Data)
	}
	return nil
}

// ledgerSource is the canonical session ledger envelope.
//
// Example: ledgerSource is the canonical session ledger envelope.
type ledgerSource struct {
	Schema   string                  `yaml:"schema"`
	Sections map[string]any          `yaml:"sections"`
	Records  map[string]sourceRecord `yaml:"records"`
}

// forecastSource is the canonical forecast envelope.
//
// Example: forecastSource is the canonical forecast envelope.
type forecastSource struct {
	Schema  string                    `yaml:"schema"`
	Records map[string]map[string]any `yaml:"records"`
}

// sourceID extracts a semantic record key from a validated locator.
//
// Example: sourceID extracts a semantic record key from a validated locator.
func sourceID(
	ref string,
	file string,
) string {
	return strings.TrimPrefix(ref, file+"#/records/")
}

// validRef checks the expected canonical locator prefix and key.
//
// Example: validRef checks the expected canonical locator prefix and key.
func validRef(
	ref string,
	file string,
) bool {
	return strings.HasPrefix(ref, file+"#/records/") && sourceID(ref, file) != ""
}

// readSource decodes exactly one canonical YAML document.
//
// Example: readSource decodes exactly one canonical YAML document.
func readSource(
	path string,
	dst any,
) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	decoder := yaml.NewDecoder(bytes.NewReader(b))
	if err := decoder.Decode(dst); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple YAML documents")
		}
		return err
	}
	return nil
}

// textField returns a string source field or an empty value.
//
// Example: textField returns a string source field or an empty value.
func textField(
	m map[string]any,
	k string,
) string {
	if v, ok := m[k].(string); ok {
		return v
	}
	return ""
}

// sameValue compares strings or equivalent UTC instants.
//
// Example: sameValue compares strings or equivalent UTC instants.
func sameValue(
	a string,
	b string,
) bool {
	if a == b {
		return true
	}
	x, e := parseUTC(a)
	if e != nil {
		return false
	}
	y, e := parseUTC(b)
	return e == nil && x.Equal(y)
}

// projectionEqual recursively compares source projections, including UTC instants.
//
// Example: projectionEqual recursively compares source projections, including UTC instants.
func projectionEqual(
	a any,
	b any,
) bool {
	switch x := a.(type) {
	case string:
		y, ok := b.(string)
		return ok && sameValue(x, y)
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, v := range x {
			w, ok := y[k]
			if !ok || !projectionEqual(v, w) {
				return false
			}
		}
		return true
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !projectionEqual(x[i], y[i]) {
				return false
			}
		}
		return true
	default:
		return reflect.DeepEqual(a, b)
	}
}

// forecastStructure reports missing fields in native forecast detail.
//
// Example: forecastStructure reports missing fields in native forecast detail.
func forecastStructure(src map[string]any) []string {
	var issues []string
	if raw, ok := src["base_case"]; ok {
		issues = append(issues, checkBaseCase(raw)...)
	}
	if raw, ok := src["scenarios"]; ok {
		issues = append(issues, checkForecastScenarios(raw)...)
	}
	return issues
}

// checkBaseCase validates the base endpoint and package details.
//
// Example: checkBaseCase validates the base endpoint and package details.
func checkBaseCase(raw any) []string {
	base, ok := raw.(map[string]any)
	if !ok {
		return []string{"base_case must be a mapping"}
	}
	var issues []string
	if textField(base, "endpoint") == "" {
		issues = append(issues, "base_case missing endpoint")
	}
	packages, ok := base["packages"].([]any)
	if !ok || len(packages) == 0 {
		issues = append(issues, "base_case missing packages")
	}
	for _, item := range packages {
		issues = append(issues, checkForecastFields(item, "base_case package", []string{"work", "duration", "basis"})...)
	}
	return issues
}

// checkForecastScenarios validates each supplied material downside scenario.
//
// Example: checkForecastScenarios validates each supplied material downside scenario.
func checkForecastScenarios(raw any) []string {
	scenarios, ok := raw.([]any)
	if !ok {
		return []string{"scenarios must be a list"}
	}
	var issues []string
	for _, item := range scenarios {
		issues = append(issues, checkForecastFields(item, "scenario", []string{"name", "trigger", "affected_work", "evidence", "assumptions", "added_duration", "event_time", "endpoint", "basis"})...)
	}
	return issues
}

// checkForecastFields checks required fields in one native forecast mapping.
//
// Example: checkForecastFields checks required fields in one native forecast mapping.
func checkForecastFields(
	raw any,
	name string,
	fields []string,
) []string {
	values, ok := raw.(map[string]any)
	if !ok {
		return []string{"invalid " + name}
	}
	var issues []string
	for _, field := range fields {
		if textField(values, field) == "" {
			issues = append(issues, name+" missing "+field)
		}
	}
	return issues
}

// hasRole checks an explicitly declared reporting responsibility.
//
// Example: hasRole checks an explicitly declared reporting responsibility.
func hasRole(
	roles []string,
	role string,
) bool {
	for _, r := range roles {
		if r == role {
			return true
		}
	}
	return false
}

// ledgerRecordIssues checks the source fields needed for coverage decisions.
//
// Example: Report a missing owner on active work.
func ledgerRecordIssues(
	id string,
	record sourceRecord,
	sections map[string]any,
) []string {
	var issues []string
	if record.Type == "" || record.Section == "" {
		issues = append(issues, fmt.Sprintf("ledger record %s missing type or section", id))
	}
	if _, ok := sections[record.Section]; record.Type != "" && record.Section != "" && !ok {
		issues = append(issues, fmt.Sprintf("ledger record %s references unknown section %s", id, record.Section))
	}
	if record.Type != "work" {
		return issues
	}
	if record.Data.Owner == "" {
		issues = append(issues, fmt.Sprintf("work %s missing owner", id))
	}
	if openWork(record.Data.State) && record.Data.NextAction == "" {
		issues = append(issues, fmt.Sprintf("work %s missing next action", id))
	}
	switch record.Data.State {
	case "active", "blocked", "completed", "cancelled":
	default:
		issues = append(issues, fmt.Sprintf("work %s has unknown state", id))
	}
	if record.Data.Roles == nil {
		issues = append(issues, fmt.Sprintf("work %s reporting roles unverified", id))
	}
	for _, role := range record.Data.Roles {
		if role != "lane" && role != "root" {
			issues = append(issues, fmt.Sprintf("work %s has unknown reporting role %s", id, role))
		}
	}
	return issues
}

// reconcile checks a report against canonical session sources without mutation.
//
// Example: reconcile checks a report against canonical session sources without mutation.
func reconcile(
	r report,
	dir string,
) []string {
	var issues []string
	add := // add appends one source reconciliation issue.
		//
		// Example: Record an unresolved forecast.
		func(format string, args ...any) { issues = append(issues, fmt.Sprintf(format, args...)) }
	if !*r.ScopeComplete {
		add("report declares scope incomplete")
	}
	if dir == "" {
		return append(issues, "session context unavailable; coverage and forecasts unverified")
	}
	var ledger ledgerSource
	if err := readSource(filepath.Join(dir, "project-understanding.yaml"), &ledger); err != nil || ledger.Schema != "project-understanding/v1" || ledger.Sections == nil || ledger.Records == nil {
		if _, err := os.Stat(filepath.Join(dir, "forecasts.yaml")); err != nil {
			add("forecast source unavailable; applicability unverified")
		}
		return append(issues, "ledger unavailable, malformed, or unsupported; coverage and forecasts unverified")
	}
	works := map[string]sourceRecord{}
	for id, rec := range ledger.Records {
		issues = append(issues, ledgerRecordIssues(id, rec, ledger.Sections)...)
		if rec.Type == "work" {
			works[id] = rec
		}
	}
	scope := buildTaskWorkIndex(r.Tasks, works)
	children := map[taskID]bool{}
	for _, t := range r.Tasks {
		if t.ParentID != "" {
			children[t.ParentID] = true
		}
	}
	allClosed := true
	for _, t := range r.Tasks {
		if !children[t.ID] && t.Status != statusClosed {
			allClosed = false
		}
	}
	lanes := map[string]lane{}
	rootRefs := map[string]bool{}
	resolve := // resolve maps a canonical locator to its work identity.
		//
		// Example: Resolve a task work reference.
		func(ref string) string {
			if !validRef(ref, "project-understanding.yaml") {
				add("invalid work reference %q", ref)
				return ""
			}
			id := sourceID(ref, "project-understanding.yaml")
			if _, ok := works[id]; !ok {
				add("unknown work reference %q", ref)
				return ""
			}
			return id
		}
	for _, t := range r.Tasks {
		for _, ref := range t.WorkRefs {
			resolve(ref)
		}
	}
	rootCompletions := map[string]rootCompletion{}
	for _, c := range r.RootCompletions {
		if id := resolve(c.WorkRef); id != "" {
			if _, ok := rootCompletions[id]; ok {
				add("duplicate root completion %s", id)
			}
			rootCompletions[id] = c
			w := works[id]
			if !hasRole(w.Data.Roles, "root") || w.Data.State != "completed" {
				add("root completion %s does not reference completed root work", id)
			}
			matched := false
			for _, outcomeID := range w.OutcomeRefs {
				if ledger.Records[outcomeID].Type == "outcome" && ledger.Records[outcomeID].Outcome == c.Outcome {
					matched = true
				}
			}
			if !matched {
				add("root completion %s outcome unverified against linked outcomes", id)
			}
			if !sameValue(w.Data.CompletedAt, c.CompletedAt) {
				add("root completion %s completed_at mismatch: source %q; report %q", id, w.Data.CompletedAt, c.CompletedAt)
			}
		}
	}
	for _, l := range r.Lanes {
		if id := resolve(l.WorkRef); id != "" {
			if !hasRole(works[id].Data.Roles, "lane") {
				add("work %s is not declared a lane", id)
			}
			if _, ok := lanes[id]; ok {
				add("duplicate lane for %s", id)
			}
			lanes[id] = l
		}
	}
	forecastCounts := map[string]int{}
	for _, f := range r.RootForecasts {
		rootRefs[f.ForecastRef] = true
		forecastCounts[f.ForecastRef]++
	}
	for _, l := range r.Lanes {
		if l.Forecast != nil {
			forecastCounts[l.Forecast.ForecastRef]++
		}
	}
	for ref, count := range forecastCounts {
		if count > 1 {
			add("duplicate report forecast reference %q", ref)
		}
	}
	usedForecasts := map[string]bool{}
	var forecasts forecastSource
	loaded := false
	loadForecasts := // loadForecasts reads the canonical forecasts once.
		//
		// Example: Load forecasts for an active lane.
		func() bool {
			if !loaded {
				loaded = true
				if err := readSource(filepath.Join(dir, "forecasts.yaml"), &forecasts); err != nil || forecasts.Schema != "forecasts/v1" || forecasts.Records == nil {
					add("forecasts unavailable, malformed, or unsupported")
					return false
				}
			}
			return forecasts.Records != nil
		}
	checkForecast := // checkForecast compares one applicable source and projection.
		//
		// Example: Compare an active lane forecast.
		func(
			ref string,
			f *forecast,
			kind string,
			open bool,
		) {
			if f != nil {
				usedForecasts[f.ForecastRef] = true
			}
			if !validRef(ref, "forecasts.yaml") {
				add("invalid or missing forecast reference %q", ref)
				return
			}
			if !loadForecasts() {
				return
			}
			id := sourceID(ref, "forecasts.yaml")
			src, ok := forecasts.Records[id]
			if !ok {
				add("forecast %s missing", id)
				return
			}
			if textField(src, "kind") != kind {
				add("forecast %s kind mismatch", id)
			}
			for _, field := range []string{"kind", "status", "outcome", "assessment", "original_baseline", "baseline_evidence"} {
				if textField(src, field) == "" {
					add("forecast %s source missing required %s", id, field)
				}
			}
			recal, ok := src["recalibration"].(map[string]any)
			if !ok {
				add("forecast %s source missing recalibration", id)
			}
			if ok {
				status := textField(recal, "status")
				if status != "unchanged" && status != "changed" {
					add("forecast %s source has invalid recalibration status", id)
				}
				if textField(recal, "evidence") == "" {
					add("forecast %s source missing recalibration evidence", id)
				}
				if status == "changed" {
					for _, field := range []string{"prior", "current", "reason"} {
						if textField(recal, field) == "" {
							add("forecast %s source missing recalibration %s", id, field)
						}
					}
				}
			}
			for _, issue := range forecastStructure(src) {
				add("forecast %s source %s", id, issue)
			}
			assessment := textField(src, "assessment")
			if assessment != "complete" && assessment != "provisional" {
				add("forecast %s source has invalid assessment %q", id, assessment)
			}
			if assessment == "provisional" && textField(src, "target_basis") == "" {
				add("forecast %s provisional source missing target_basis", id)
			}
			state := textField(src, "status")
			if state != "active" && state != "inactive" {
				add("forecast %s source has invalid status %q", id, state)
			}
			if open && textField(src, "target") == "" {
				add("forecast %s source missing required target", id)
			}
			if open && state != "active" {
				add("forecast %s is not active", id)
			}
			if !open && state == "active" {
				add("closed work has active forecast %s", id)
			}
			if !open {
				if f != nil {
					add("terminal work has report forecast %s", id)
				}
				return
			}
			if f == nil {
				add("forecast %s missing from report", id)
				return
			}
			if f.Target == "unknown" || f.Assessment == "unknown" {
				add("forecast %s has unknown target or assessment", id)
			}
			if f.ForecastRef != ref {
				add("forecast %s reference mismatch", id)
			}
			for _, v := range []struct{ k, got string }{{"outcome", f.Outcome}, {"target", f.Target}, {"assessment", f.Assessment}, {"original_baseline", f.Baseline}} {
				if !sameValue(textField(src, v.k), v.got) {
					add("forecast %s %s mismatch: source %q; report %q", id, v.k, textField(src, v.k), v.got)
				}
			}
			if rec, ok := src["recalibration"].(map[string]any); ok {
				if current := textField(rec, "current"); current != "" && !sameValue(current, f.Target) {
					add("forecast %s recalibration current mismatch: source %q; report %q", id, current, f.Target)
				}
				for _, v := range []struct{ k, got string }{{"prior", f.Prior}, {"reason", f.Reason}, {"evidence", f.Evidence}} {
					if !sameValue(textField(rec, v.k), v.got) {
						add("forecast %s recalibration %s mismatch", id, v.k)
					}
				}
			}
			if len(f.Scenarios) > 0 {
				add("forecast %s report scenarios cannot be verified against canonical scenarios; use source_projection", id)
			}
			for k := range src {
				switch k {
				case "kind", "status", "outcome", "target", "assessment", "original_baseline", "recalibration", "target_basis", "baseline_evidence", "base_case", "scenarios":
				default:
					add("forecast %s source field %s is unsupported", id, k)
				}
			}
			for k := range f.SourceProjection {
				if k != "target_basis" && k != "baseline_evidence" && k != "base_case" && k != "scenarios" {
					add("forecast %s unsupported source_projection field %s", id, k)
				}
			}
			for _, k := range []string{"target_basis", "baseline_evidence", "base_case", "scenarios"} {
				source, present := src[k]
				projected, supplied := f.SourceProjection[k]
				if k == "baseline_evidence" && !supplied && textField(src, k) == f.Evidence {
					continue
				}
				if present != supplied || (present && !projectionEqual(source, projected)) {
					add("forecast %s %s projection mismatch or missing", id, k)
				}
			}
			if target, err := parseUTC(textField(src, "target")); err == nil {
				at, _ := parseUTC(r.Timestamp)
				if !target.After(at) {
					add("forecast %s target elapsed while work open", id)
				}
			}
		}
	ids := make([]string, 0, len(works))
	for id := range works {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		w := works[id]
		open := openWork(w.Data.State)
		if open && !scope.covered[workID(id)] {
			add("active work %s missing from task coverage", id)
		}
		l, represented := lanes[id]
		if open && scope.covered[workID(id)] && !scope.remaining[workID(id)] {
			if represented && l.requiredStatus() != statusClosed && l.Lifecycle != "cancelled" && allClosed {
				add("work %s remaining acceptance is represented by an open lane outside scored leaf packages", id)
			}
			if !represented || l.requiredStatus() == statusClosed || l.Lifecycle == "cancelled" {
				add("active work %s has no remaining package or open acceptance lane", id)
			}
		}
		if w.Data.ForecastRef != "" && !hasRole(w.Data.Roles, "lane") && !hasRole(w.Data.Roles, "root") {
			if !validRef(w.Data.ForecastRef, "forecasts.yaml") {
				add("work %s has invalid forecast reference", id)
			}
			if validRef(w.Data.ForecastRef, "forecasts.yaml") && loadForecasts() {
				source, ok := forecasts.Records[sourceID(w.Data.ForecastRef, "forecasts.yaml")]
				if !ok || textField(source, "status") != "inactive" {
					add("work %s forecast has no applicable reporting role", id)
				}
			}
		}
		if w.Data.State == "completed" && (hasRole(w.Data.Roles, "lane") || hasRole(w.Data.Roles, "root")) {
			if _, err := parseUTC(w.Data.CompletedAt); err != nil {
				add("completed work %s missing or invalid completed_at", id)
			}
			if represented && !sameValue(w.Data.CompletedAt, l.CompletedAt) {
				add("work %s completed_at mismatch: source %q; report %q", id, w.Data.CompletedAt, l.CompletedAt)
			}
			if !represented && !hasRole(w.Data.Roles, "root") {
				add("completed forecasted work %s completion projection unverified", id)
			}
		}
		if hasRole(w.Data.Roles, "lane") {
			if !represented {
				if w.Data.State != "cancelled" {
					add("declared lane %s missing from report", id)
				}
				if w.Data.State == "cancelled" && w.Data.ForecastRef != "" {
					checkForecast(w.Data.ForecastRef, nil, "lane", false)
				}
			}
			if represented {
				if open && l.requiredStatus() == statusClosed {
					add("open lane %s reported closed", id)
				}
				if w.Data.State == "completed" && l.requiredStatus() != statusClosed {
					add("closed lane %s reported open", id)
				}
				if w.Data.State == "cancelled" && l.Lifecycle != "cancelled" {
					add("cancelled lane %s lifecycle is not marked cancelled", id)
				}
				if w.Data.State != "cancelled" && l.Lifecycle != "" {
					add("lane %s lifecycle conflicts with source state", id)
				}
				if w.Data.State == "cancelled" && l.CompletedAt != "" {
					add("cancelled lane %s must not claim completion", id)
				}
				if w.Data.ForecastRef != "" || forecastApplicable(w, "lane", represented) || l.Forecast != nil {
					checkForecast(w.Data.ForecastRef, l.Forecast, "lane", open)
				}
			}
		}
		if hasRole(w.Data.Roles, "root") && !represented && !(w.Data.State == "cancelled" && hasRole(w.Data.Roles, "lane")) {
			if w.Data.State == "completed" {
				if _, ok := rootCompletions[id]; !ok {
					add("completed root %s completion missing from report", id)
				}
			}
			if forecastApplicable(w, "root", represented) && !rootRefs[w.Data.ForecastRef] {
				add("active root %s forecast missing from report", id)
			}
			var f *forecast
			for i := range r.RootForecasts {
				if r.RootForecasts[i].ForecastRef == w.Data.ForecastRef {
					f = &r.RootForecasts[i]
					break
				}
			}
			if w.Data.ForecastRef != "" || open {
				checkForecast(w.Data.ForecastRef, f, "root", open)
			}
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "forecasts.yaml")); err == nil && loadForecasts() {
		claimed := map[string]bool{}
		for _, w := range works {
			if w.Data.ForecastRef != "" {
				claimed[w.Data.ForecastRef] = true
			}
		}
		for id, source := range forecasts.Records {
			if textField(source, "status") == "active" && !claimed["forecasts.yaml#/records/"+id] {
				add("active canonical forecast %s is not linked to work", id)
			}
		}
	}
	for _, f := range r.RootForecasts {
		if !usedForecasts[f.ForecastRef] {
			add("root forecast %q is not linked to applicable work", f.ForecastRef)
		}
	}
	for _, l := range r.Lanes {
		if l.Forecast != nil && !usedForecasts[l.Forecast.ForecastRef] {
			add("lane forecast %q is not linked to applicable work", l.Forecast.ForecastRef)
		}
	}
	at, _ := parseUTC(r.Timestamp)
	estimates := append([]completionEstimate{}, r.PriorityEstimates...)
	if r.CompletionEstimate != nil {
		estimates = append(estimates, *r.CompletionEstimate)
	}
	anyOpen := false
	for _, w := range works {
		if w.Data.State == "active" || w.Data.State == "blocked" {
			anyOpen = true
		}
	}
	for _, e := range estimates {
		relevantOpen := anyOpen
		if e.Priority != "" {
			relevantOpen = scope.priorityOpen(e.Priority, lanes)
		}
		base, err := parseUTC(e.AsOf)
		if err != nil {
			continue
		}
		if base.After(at) {
			add("completion estimate as_of %s is in the future", e.AsOf)
		}
		if !base.After(at) && relevantOpen && e.MaxMinutes != nil && !base.Add(time.Duration(float64(*e.MaxMinutes)*float64(time.Minute))).After(at) {
			add("completion estimate as_of %s endpoint elapsed while work open", e.AsOf)
		}
	}
	return issues
}
