package main

import (
	"os"
	"path/filepath"
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
