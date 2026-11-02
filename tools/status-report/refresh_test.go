package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRefreshRequirementChangePreservesReport(t *testing.T) {
	dir := t.TempDir()
	original := strings.Replace(linkedReport, "status: IN PROGRESS", "status: CLOSED, evidence: accepted", 1)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(original), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.NoError(t, refreshStatus(dir, "requirement_change"))
	first, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(first), "scope_complete: false")
	require.Contains(t, string(first), refreshDiagnostic)
	require.Contains(t, string(first), "status: CLOSED")
	require.NoError(t, refreshStatus(dir, "requirement_change"))
	second, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, first, second)
}

func TestRefreshRejectsMissingOrInvalidReport(t *testing.T) {
	dir := t.TempDir()
	require.Error(t, refreshStatus(dir, "requirement_change"))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "latest-status-report.yaml"), []byte("scope_complete: nope\n"), 0600))
	require.Error(t, refreshStatus(dir, "requirement_change"))
}

func TestRefreshDetectsConcurrentReportMutation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	changed := []byte(linkedReport + "# concurrent edit\n")
	refreshBeforePublish = func() { require.NoError(t, os.WriteFile(path, changed, 0600)) }
	t.Cleanup(func() { refreshBeforePublish = func() {} })
	require.ErrorContains(t, refreshStatus(dir, "requirement_change"), "retry needed")
	actual, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, changed, actual)
	refreshBeforePublish = func() {}
	require.NoError(t, refreshStatus(dir, "requirement_change"))
}

func TestRefreshProjectsLinkedForecast(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	changed := strings.Replace(linkedForecasts, "target: '2026-11-02T16:00:00+00:00'", "target: '2026-11-02T16:30:00Z'", 1)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(changed), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "2026-11-02T16:30:00Z")
	require.Contains(t, string(result), "2026-11-02T17:00:00Z")
}

func TestForecastRefreshRejectsConcurrentSourceMutation(t *testing.T) {
	dir := t.TempDir()
	reportPath := filepath.Join(dir, "latest-status-report.yaml")
	forecastPath := filepath.Join(dir, "forecasts.yaml")
	require.NoError(t, os.WriteFile(reportPath, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	changed := strings.Replace(linkedForecasts, "target: '2026-11-02T16:00:00+00:00'", "target: '2026-11-02T16:30:00Z'", 1)
	require.NoError(t, os.WriteFile(forecastPath, []byte(changed), 0600))
	refreshBeforePublish = func() { require.NoError(t, os.WriteFile(forecastPath, []byte(changed+"# concurrent\n"), 0600)) }
	t.Cleanup(func() { refreshBeforePublish = func() {} })
	require.ErrorContains(t, refreshStatus(dir, "forecast_change"), "retry needed")
	result, err := os.ReadFile(reportPath)
	require.NoError(t, err)
	require.Equal(t, linkedReport, string(result))
}

func TestRefreshProjectsForecastDetails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	source := strings.Replace(linkedForecasts, "outcome: First result", "outcome: Updated result", 1)
	source = strings.Replace(source, "    baseline_evidence: initial\n", "    baseline_evidence: initial\n    target_basis: Conditional on review\n", 1)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "Updated result")
	require.Contains(t, string(result), "Conditional on review")
}

func TestRefreshProjectsRootAndBlockForecast(t *testing.T) {
	dir := t.TempDir()
	report := linkedReport + "root_forecasts:\n  - forecast_ref: 'forecasts.yaml#/records/root'\n    outcome: Root result\n    target: '2026-11-02T16:00:00Z'\n    assessment: complete\n    baseline: '2026-11-02T16:00:00Z'\n    evidence: initial\n"
	ledger := linkedLedger + "  work:root:\n    section: progress\n    type: work\n    data: {owner: lead, state: active, next_action: Finish, reporting_roles: [root], forecast_ref: 'forecasts.yaml#/records/root'}\n    evidence: []\n"
	source := linkedForecasts + "  root:\n    kind: root\n    outcome: Root result\n    status: active\n    assessment: complete\n    target: '2026-11-02T16:30:00Z'\n    original_baseline: '2026-11-02T16:00:00Z'\n    baseline_evidence: initial\n    recalibration: {status: unchanged, evidence: initial}\n"
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(ledger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "2026-11-02T16:30:00Z")
	require.Contains(t, string(result), "source_projection")
}

func TestRefreshUpdatesExistingProjectionAndPreservesComment(t *testing.T) {
	dir := t.TempDir()
	report := strings.Replace(linkedReport, "evidence: initial}", "evidence: initial, source_projection: {baseline_evidence: initial, target_basis: old}} # keep this comment", 1)
	source := strings.Replace(linkedForecasts, "    baseline_evidence: initial\n", "    baseline_evidence: initial\n    target_basis: new basis\n", 1)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "new basis")
	require.Contains(t, string(result), "# keep this comment")
}

func TestRefreshPersistsUnsupportedProjectionDiagnostic(t *testing.T) {
	dir := t.TempDir()
	report := strings.Replace(linkedReport, "    forecast: {forecast_ref: 'forecasts.yaml#/records/first', outcome: First result, target: '2026-11-02T16:00:00Z', assessment: complete, baseline: '2026-11-02T16:00:00Z', evidence: initial}", "    forecast:\n      forecast_ref: 'forecasts.yaml#/records/first'\n      outcome: First result\n      target: '2026-11-02T16:00:00Z'\n      assessment: complete\n      baseline: '2026-11-02T16:00:00Z'\n      evidence: initial\n      source_projection:\n        target_basis: old # retain this note", 1)
	source := strings.Replace(linkedForecasts, "    baseline_evidence: initial\n", "    baseline_evidence: initial\n    target_basis: new\n", 1)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.ErrorContains(t, refreshStatus(dir, "forecast_change"), "manual refresh required")
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "scope_complete: false")
	require.Contains(t, string(result), "forecasts.yaml#/records/first")
	require.Contains(t, string(result), "# retain this note")
}

func TestRequirementChangeAtomicallyProjectsForecast(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	source := strings.Replace(linkedForecasts, "target: '2026-11-02T16:00:00+00:00'", "target: '2026-11-02T16:30:00Z'", 1)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "requirement_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "scope_complete: false")
	require.Contains(t, string(result), refreshDiagnostic)
	require.Contains(t, string(result), "2026-11-02T16:30:00Z")
}

func TestRefreshDirectWorkWithoutForecast(t *testing.T) {
	dir := t.TempDir()
	report := strings.Replace(valid, "scope_complete: false", "scope_complete: true", 1)
	report = strings.Replace(report, "status: unknown", "status: IN PROGRESS", 1)
	report = strings.Replace(report, "title: Root", "title: Root\n    work_refs: ['project-understanding.yaml#/records/work:direct']", 1)
	ledger := "schema: project-understanding/v1\nsections: {progress: {title: Progress}}\nrecords:\n  work:direct:\n    section: progress\n    type: work\n    data: {owner: one, state: active, next_action: Finish, reporting_roles: []}\n    evidence: []\n"
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(ledger), 0600))
	require.NoError(t, refreshStatus(dir, "decision"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, report, string(result))
	var out, errOut strings.Builder
	require.Equal(t, 0, run([]string{"refresh", dir, "decision"}, strings.NewReader(""), &out, &errOut))
	require.Empty(t, errOut.String())
}

func TestRefreshPersistsMissingWorkDiagnostic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	ledger := strings.Replace(linkedLedger, "work:first:", "work:missing:", 1)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(ledger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.NoError(t, refreshStatus(dir, "decision"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "scope_complete: false")
	require.Contains(t, string(result), "Status refresh incomplete:")
	require.Contains(t, string(result), "work:first")
}

func TestRefreshRejectsInvalidForecastSources(t *testing.T) {
	cases := []struct{ name, from, to, issue string }{
		{"missing outcome", "    outcome: First result\n", "", "missing outcome"},
		{"bad target", "target: '2026-11-02T16:00:00+00:00'", "target: invalid", "invalid target"},
		{"unknown assessment", "assessment: complete", "assessment: unknown", "invalid assessment"},
		{"missing provisional basis", "assessment: complete", "assessment: provisional", "missing target_basis"},
		{"bad recalibration", "recalibration: {status: unchanged, evidence: initial}", "recalibration: {status: invalid, evidence: initial}", "invalid recalibration"},
		{"unsupported field", "    kind: lane\n", "    kind: lane\n    extra: value\n", "unsupported source field extra"},
		{"missing changed details", "recalibration: {status: unchanged, evidence: initial}", "recalibration: {status: changed, evidence: initial}", "recalibration missing prior"},
		{"changed current differs", "recalibration: {status: unchanged, evidence: initial}", "recalibration: {status: changed, prior: '2026-11-02T15:00:00Z', current: '2026-11-02T17:00:00Z', reason: review, evidence: initial}", "recalibration current does not match target"},
		{"missing lane forecast", "    kind: lane\n", "    kind: root\n", "not an active lane forecast"},
		{"invalid source scenario", "    baseline_evidence: initial\n", "    baseline_evidence: initial\n    scenarios: [invalid]\n", "invalid scenario"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "latest-status-report.yaml")
			require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
			require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
			require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(strings.Replace(linkedForecasts, tc.from, tc.to, 1)), 0600))
			require.ErrorContains(t, refreshStatus(dir, "forecast_change"), tc.issue)
			result, err := os.ReadFile(path)
			require.NoError(t, err)
			require.Contains(t, string(result), "scope_complete: false")
			require.Contains(t, string(result), tc.issue)
		})
	}
}

func TestRefreshCLIArgumentsAndFailures(t *testing.T) {
	var errOut strings.Builder
	require.Equal(t, 2, runRefresh(nil, &errOut))
	require.Contains(t, errOut.String(), "usage")
	errOut.Reset()
	require.Equal(t, 1, runRefresh([]string{t.TempDir(), "requirement_change"}, &errOut))
	require.Contains(t, errOut.String(), "status-report refresh")
}

func TestRefreshProjectsFullScenario(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	sourceProjection := "    base_case:\n      endpoint: '2026-11-02T15:45:00Z'\n      packages:\n        - {work: Finish, duration: 20 minutes, basis: guess}\n    scenarios:\n      - {name: Delay, trigger: review, affected_work: Finish, evidence: unknown, assumptions: none, added_duration: 15 minutes, event_time: '2026-11-02T15:45:00Z', endpoint: '2026-11-02T16:00:00Z', basis: guess}\n"
	source := strings.Replace(linkedForecasts, "    baseline_evidence: initial\n", "    baseline_evidence: initial\n"+sourceProjection, 1)
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "added_duration")
	require.Contains(t, string(result), "event_time")
	parsed, err := parse(result)
	require.NoError(t, err)
	require.Empty(t, reconcile(parsed, dir))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	again, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, result, again)
}

func TestInvalidatePreservesBlockListIndentation(t *testing.T) {
	for _, indent := range []string{"", "  "} {
		t.Run("indent_"+strconv.Itoa(len(indent)), func(t *testing.T) {
			report := strings.Replace(linkedReport, "blockers_risks: []", "blockers_risks:\n"+indent+"- existing", 1)
			updated, err := prepareInvalidation([]byte(report), refreshDiagnostic)
			require.NoError(t, err)
			parsed, err := parse(updated)
			require.NoError(t, err)
			require.Contains(t, parsed.Blockers, "existing")
			require.Contains(t, parsed.Blockers, refreshDiagnostic)
		})
	}
	report := strings.Replace(linkedReport, "blockers_risks: []", "blockers_risks:\n  - |\n    multiple\n    lines", 1)
	_, err := prepareInvalidation([]byte(report), refreshDiagnostic)
	require.ErrorContains(t, err, "multiline blocker")
}

func TestRefreshUpdatesBlockSourceProjection(t *testing.T) {
	dir := t.TempDir()
	report := strings.Replace(linkedReport, "    forecast: {forecast_ref: 'forecasts.yaml#/records/first', outcome: First result, target: '2026-11-02T16:00:00Z', assessment: complete, baseline: '2026-11-02T16:00:00Z', evidence: initial}", "    forecast:\n      forecast_ref: 'forecasts.yaml#/records/first'\n      outcome: First result\n      target: '2026-11-02T16:00:00Z'\n      assessment: complete\n      baseline: '2026-11-02T16:00:00Z'\n      evidence: initial\n      source_projection:\n        baseline_evidence: initial\n        target_basis: old", 1)
	source := strings.Replace(linkedForecasts, "    baseline_evidence: initial\n", "    baseline_evidence: initial\n    target_basis: new\n", 1)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "new")
	parsed, err := parse(result)
	require.NoError(t, err)
	require.Empty(t, reconcile(parsed, dir))
}

func TestRefreshRejectsUnsafeOrMissingSources(t *testing.T) {
	t.Run("symlink report", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "target")
		require.NoError(t, os.WriteFile(target, []byte(linkedReport), 0600))
		require.NoError(t, os.Symlink(target, filepath.Join(dir, "latest-status-report.yaml")))
		require.ErrorContains(t, refreshStatus(dir, "requirement_change"), "not a regular file")
		b, err := os.ReadFile(target)
		require.NoError(t, err)
		require.Equal(t, linkedReport, string(b))
	})
	t.Run("missing forecast", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "latest-status-report.yaml")
		require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
		require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
		require.Error(t, refreshStatus(dir, "requirement_change"))
		b, err := os.ReadFile(path)
		require.NoError(t, err)
		require.Contains(t, string(b), refreshDiagnostic)
		require.Contains(t, string(b), "Status refresh incomplete:")
	})
	t.Run("malformed ledger", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "latest-status-report.yaml")
		require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
		require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte("[invalid"), 0600))
		require.Error(t, refreshStatus(dir, "forecast_change"))
		b, err := os.ReadFile(path)
		require.NoError(t, err)
		require.Contains(t, string(b), "Status refresh incomplete:")
	})
}

func TestRefreshProjectsRecalibration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	source := strings.Replace(linkedForecasts, "target: '2026-11-02T16:00:00+00:00'", "target: '2026-11-02T16:30:00Z'", 1)
	source = strings.Replace(source, "assessment: complete", "assessment: provisional", 1)
	source = strings.Replace(source, "    baseline_evidence: initial\n", "    baseline_evidence: initial\n    target_basis: conditional\n", 1)
	source = strings.Replace(source, "recalibration: {status: unchanged, evidence: initial}", "recalibration: {status: changed, prior: '2026-11-02T16:00:00Z', current: '2026-11-02T16:30:00Z', reason: review, evidence: evidence}", 1)
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	parsed, err := parse(result)
	require.NoError(t, err)
	require.Empty(t, reconcile(parsed, dir))
	require.Contains(t, string(result), "conditional")
	require.Contains(t, string(result), "review")
}

func TestRefreshMissingRootForecastPersistsDiagnostic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	report := linkedReport + "root_forecasts:\n  - {forecast_ref: 'forecasts.yaml#/records/root', outcome: Root, target: '2026-11-02T16:00:00Z', assessment: complete}\n"
	ledger := linkedLedger + "  work:root:\n    section: progress\n    type: work\n    data: {owner: lead, state: active, next_action: Finish, reporting_roles: [root], forecast_ref: 'forecasts.yaml#/records/root'}\n    evidence: []\n"
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(ledger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.ErrorContains(t, refreshStatus(dir, "forecast_change"), "not an active root forecast")
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "forecasts.yaml#/records/root")
	require.Contains(t, string(result), "scope_complete: false")
}

func TestRefreshHandlesConcurrentReplacementAndDeletion(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*testing.T, string)
	}{
		{"replace report", func(t *testing.T, dir string) {
			path := filepath.Join(dir, "latest-status-report.yaml")
			replacement := filepath.Join(dir, "replacement")
			require.NoError(t, os.WriteFile(replacement, []byte(linkedReport), 0600))
			require.NoError(t, os.Rename(replacement, path))
		}},
		{"remove forecast", func(t *testing.T, dir string) { require.NoError(t, os.Remove(filepath.Join(dir, "forecasts.yaml"))) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "latest-status-report.yaml")
			require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
			require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
			require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
			refreshBeforePublish = func() { tc.mutate(t, dir) }
			t.Cleanup(func() { refreshBeforePublish = func() {} })
			require.Error(t, refreshStatus(dir, "requirement_change"))
			b, err := os.ReadFile(path)
			require.NoError(t, err)
			require.Equal(t, linkedReport, string(b))
		})
	}
}

func TestRefreshRejectsStaleRecalibrationFields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	report := strings.Replace(linkedReport, "evidence: initial}", "evidence: initial, reason: obsolete}", 1)
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.ErrorContains(t, refreshStatus(dir, "forecast_change"), "stale reason")
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "Status refresh incomplete:")
	require.Contains(t, string(result), "reason: obsolete")
}

func TestInvalidateFlowListPreservesQuotedClosingBracket(t *testing.T) {
	original := strings.Replace(linkedReport, "blockers_risks: []", "blockers_risks: ['risk ] here', 'don''t ] split', \"quoted \\\" ] here\"]", 1)
	updated, err := prepareInvalidation([]byte(original), refreshDiagnostic)
	require.NoError(t, err)
	parsed, err := parse(updated)
	require.NoError(t, err)
	require.Equal(t, []string{"risk ] here", "don't ] split", "quoted \" ] here", refreshDiagnostic}, parsed.Blockers)
	again, err := prepareInvalidation(updated, refreshDiagnostic)
	require.NoError(t, err)
	require.Equal(t, updated, again)
}

func TestRefreshChangesQuotedOutcomeWithoutDamagingOtherFields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	report := strings.Replace(linkedReport, "outcome: First result, target:", "outcome: 'Worker''s {old}', target:", 1)
	source := strings.Replace(linkedForecasts, "    outcome: First result", "    outcome: 'Worker''s new result'", 1)
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(source), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	parsed, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, "Worker's new result", parsed.Lanes[0].Forecast.Outcome)
	require.Equal(t, "2026-11-02T17:00:00Z", parsed.Lanes[1].Forecast.Target)
}

func TestRefreshDoesNotClearScopeOrPriorDiagnostic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	ledgerPath := filepath.Join(dir, "project-understanding.yaml")
	require.NoError(t, os.WriteFile(ledgerPath, []byte(strings.Replace(linkedLedger, "work:first:", "work:missing:", 1)), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.NoError(t, refreshStatus(dir, "requirement_change"))
	require.NoError(t, os.WriteFile(ledgerPath, []byte(linkedLedger), 0600))
	require.NoError(t, refreshStatus(dir, "decision"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "scope_complete: false")
	require.Contains(t, string(result), refreshDiagnostic)
	require.Contains(t, string(result), "work:first")
}

func TestRequirementChangeSourceFailurePublishesOnce(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	publications := 0
	refreshBeforePublish = func() { publications++ }
	t.Cleanup(func() { refreshBeforePublish = func() {} })
	require.Error(t, refreshStatus(dir, "requirement_change"))
	require.Equal(t, 1, publications)
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), refreshDiagnostic)
	require.Contains(t, string(result), "Status refresh incomplete:")
}

func TestRefreshPreservesMultilineForecastScalar(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	old := "    forecast: {forecast_ref: 'forecasts.yaml#/records/first', outcome: First result, target: '2026-11-02T16:00:00Z', assessment: complete, baseline: '2026-11-02T16:00:00Z', evidence: initial}"
	block := "    forecast:\n      forecast_ref: 'forecasts.yaml#/records/first'\n      outcome: |-\n        First result\n        with detail\n      target: '2026-11-02T16:00:00Z'\n      assessment: complete\n      baseline: '2026-11-02T16:00:00Z'\n      evidence: initial"
	report := strings.Replace(linkedReport, old, block, 1)
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.ErrorContains(t, refreshStatus(dir, "forecast_change"), "multiline forecast scalar")
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "First result\n        with detail")
	require.Contains(t, string(result), "Status refresh incomplete:")
}

func TestRefreshPreservesFlowCommentWithClosingBrace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	before := "forecast: {forecast_ref: 'forecasts.yaml#/records/first'"
	after := "forecast: {\n      # context } untouched\n      forecast_ref: 'forecasts.yaml#/records/first'"
	report := strings.Replace(linkedReport, before, after, 1)
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.NoError(t, refreshStatus(dir, "forecast_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Contains(t, string(result), "# context } untouched")
	parsed, err := parse(result)
	require.NoError(t, err)
	require.NotEmpty(t, parsed.Lanes[0].Forecast.SourceProjection)
	require.Empty(t, reconcile(parsed, dir))
}
