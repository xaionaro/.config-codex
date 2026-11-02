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

type workData struct {
	CompletedAt string   `yaml:"completed_at"`
	Owner       string   `yaml:"owner"`
	NextAction  string   `yaml:"next_action"`
	State       string   `yaml:"state"`
	Roles       []string `yaml:"reporting_roles"`
	ForecastRef string   `yaml:"forecast_ref"`
}
type sourceRecord struct {
	Type    string
	Section string
	Data    workData
}

func (r *sourceRecord) UnmarshalYAML(n *yaml.Node) error {
	var wire struct {
		Type    string    `yaml:"type"`
		Section string    `yaml:"section"`
		Data    yaml.Node `yaml:"data"`
	}
	if err := n.Decode(&wire); err != nil {
		return err
	}
	r.Type, r.Section = wire.Type, wire.Section
	if wire.Type == "work" {
		return wire.Data.Decode(&r.Data)
	}
	return nil
}

type ledgerSource struct {
	Schema   string                  `yaml:"schema"`
	Sections map[string]any          `yaml:"sections"`
	Records  map[string]sourceRecord `yaml:"records"`
}
type forecastSource struct {
	Schema  string                    `yaml:"schema"`
	Records map[string]map[string]any `yaml:"records"`
}

func sourceID(ref, file string) string { return strings.TrimPrefix(ref, file+"#/records/") }
func validRef(ref, file string) bool {
	return strings.HasPrefix(ref, file+"#/records/") && sourceID(ref, file) != ""
}
func readSource(path string, dst any) error {
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
func textField(m map[string]any, k string) string {
	if v, ok := m[k].(string); ok {
		return v
	}
	return ""
}
func sameValue(a, b string) bool {
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
func projectionEqual(a, b any) bool {
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
func forecastStructure(src map[string]any) []string {
	var issues []string
	if raw, present := src["base_case"]; present {
		base, ok := raw.(map[string]any)
		if !ok {
			issues = append(issues, "base_case must be a mapping")
		} else {
			if textField(base, "endpoint") == "" {
				issues = append(issues, "base_case missing endpoint")
			}
			packages, ok := base["packages"].([]any)
			if !ok || len(packages) == 0 {
				issues = append(issues, "base_case missing packages")
			}
			for _, rawPackage := range packages {
				p, ok := rawPackage.(map[string]any)
				if !ok {
					issues = append(issues, "invalid base_case package")
					continue
				}
				for _, k := range []string{"work", "duration", "basis"} {
					if textField(p, k) == "" {
						issues = append(issues, "base_case package missing "+k)
					}
				}
			}
		}
	}
	if raw, present := src["scenarios"]; present {
		scenarios, ok := raw.([]any)
		if !ok {
			issues = append(issues, "scenarios must be a list")
		}
		for _, rawScenario := range scenarios {
			s, ok := rawScenario.(map[string]any)
			if !ok {
				issues = append(issues, "invalid scenario")
				continue
			}
			for _, k := range []string{"name", "trigger", "affected_work", "evidence", "assumptions", "added_duration", "event_time", "endpoint", "basis"} {
				if textField(s, k) == "" {
					issues = append(issues, "scenario missing "+k)
				}
			}
		}
	}
	return issues
}

func hasRole(roles []string, role string) bool {
	for _, r := range roles {
		if r == role {
			return true
		}
	}
	return false
}

func reconcile(r report, dir string) []string {
	var issues []string
	add := func(format string, args ...any) { issues = append(issues, fmt.Sprintf(format, args...)) }
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
		if rec.Type == "" || rec.Section == "" {
			add("ledger record %s missing type or section", id)
		} else if _, ok := ledger.Sections[rec.Section]; !ok {
			add("ledger record %s references unknown section %s", id, rec.Section)
		}
		if rec.Type == "work" {
			if rec.Data.Owner == "" {
				add("work %s missing owner", id)
			}
			if (rec.Data.State == "active" || rec.Data.State == "blocked") && rec.Data.NextAction == "" {
				add("work %s missing next action", id)
			}
			works[id] = rec
			switch rec.Data.State {
			case "active", "blocked", "completed", "cancelled":
			default:
				add("work %s has unknown state", id)
			}
			if rec.Data.Roles == nil {
				add("work %s reporting roles unverified", id)
			}
			for _, role := range rec.Data.Roles {
				if role != "lane" && role != "root" {
					add("work %s has unknown reporting role %s", id, role)
				}
			}
		}
	}
	covered := map[string]bool{}
	lanes := map[string]lane{}
	rootRefs := map[string]bool{}
	resolve := func(ref string) string {
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
			if id := resolve(ref); id != "" {
				covered[id] = true
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
	loadForecasts := func() bool {
		if !loaded {
			loaded = true
			if err := readSource(filepath.Join(dir, "forecasts.yaml"), &forecasts); err != nil || forecasts.Schema != "forecasts/v1" || forecasts.Records == nil {
				add("forecasts unavailable, malformed, or unsupported")
				return false
			}
		}
		return forecasts.Records != nil
	}
	checkForecast := func(ref string, f *forecast, kind string, open bool) {
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
		} else {
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
		open := w.Data.State == "active" || w.Data.State == "blocked"
		if open && !covered[id] {
			add("active work %s missing from task coverage", id)
		}
		l, represented := lanes[id]
		if w.Data.State == "completed" && w.Data.ForecastRef != "" {
			if _, err := parseUTC(w.Data.CompletedAt); err != nil {
				add("completed forecasted work %s missing or invalid completed_at", id)
			} else if represented && !sameValue(w.Data.CompletedAt, l.CompletedAt) {
				add("work %s completed_at mismatch: source %q; report %q", id, w.Data.CompletedAt, l.CompletedAt)
			} else if !represented {
				add("completed forecasted work %s completion projection unverified", id)
			}
		}
		if hasRole(w.Data.Roles, "lane") {
			if !represented {
				add("declared lane %s missing from report", id)
			} else {
				if open && l.requiredStatus() == statusClosed {
					add("open lane %s reported closed", id)
				}
				if !open && l.requiredStatus() != statusClosed {
					add("closed lane %s reported open", id)
				}
				if w.Data.ForecastRef != "" || open || l.Forecast != nil {
					checkForecast(w.Data.ForecastRef, l.Forecast, "lane", open)
				}
			}
		}
		if hasRole(w.Data.Roles, "root") && !represented {
			if open && !rootRefs[w.Data.ForecastRef] {
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
			relevantOpen = false
			for _, t := range r.Tasks {
				if t.Priority == e.Priority {
					for _, ref := range t.WorkRefs {
						if w, ok := works[sourceID(ref, "project-understanding.yaml")]; ok && (w.Data.State == "active" || w.Data.State == "blocked") {
							relevantOpen = true
						}
					}
				}
			}
		}
		base, err := parseUTC(e.AsOf)
		if err != nil {
			continue
		}
		if base.After(at) {
			add("completion estimate as_of %s is in the future", e.AsOf)
		} else if relevantOpen && e.MaxMinutes != nil && !base.Add(time.Duration(float64(*e.MaxMinutes)*float64(time.Minute))).After(at) {
			add("completion estimate as_of %s endpoint elapsed while work open", e.AsOf)
		}
	}
	return issues
}
