package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/goccy/go-yaml/token"
	"gopkg.in/yaml.v3"
)

// refreshBeforePublish marks the publication boundary for focused concurrency tests.
//
// Example: Mutate a source immediately before the final change check.
var refreshBeforePublish =
// Callback leaves the publication boundary unchanged.
//
// Example: Run a refresh without a test mutation.
func() {}

// errRefreshRetry identifies a changed input that requires a fresh retry.
//
// Example: Retry after another writer replaces the report.
var errRefreshRetry = errors.New("retry needed")

// refreshDiagnostic names the required human scope review after a requirement change.
//
// Example: Mark scope incomplete after a requirement change.
const refreshDiagnostic = "Requirement change requires scope review and status report refresh."

// refreshLinkedStatus reads the current sources and prepares a bounded status refresh.
//
// Example: Refresh a session after a forecast change.
func refreshLinkedStatus(dir, event string) error {
	path := filepath.Join(dir, "latest-status-report.yaml")
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("report is not a regular file")
	}
	original, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if _, err := parse(original); err != nil {
		return fmt.Errorf("invalid report: %w", err)
	}
	candidate := original
	if event == "requirement_change" {
		candidate, err = prepareInvalidation(original, refreshDiagnostic)
		if err != nil {
			return err
		}
	}
	err = refreshForecastTargets(dir, path, info, original, candidate)
	if err == nil || errors.Is(err, errRefreshRetry) {
		return err
	}
	diagnostics := []string{"Status refresh incomplete: " + err.Error()}
	if event == "requirement_change" {
		diagnostics = append([]string{refreshDiagnostic}, diagnostics...)
	}
	if markErr := invalidateStatus(dir, diagnostics...); markErr != nil {
		return fmt.Errorf("%w; could not persist diagnostic: %v", err, markErr)
	}
	return err
}

// runRefresh updates the current report under the caller's ECI mutation lock.
//
// Example: Run a refresh using a session directory and event name.
func runRefresh(args []string, errOut io.Writer) int {
	if len(args) != 2 || args[0] == "" || args[1] == "" {
		fmt.Fprintln(errOut, "usage: status-report refresh SESSION_DIR EVENT")
		return 2
	}
	if err := refreshStatus(args[0], args[1]); err != nil {
		fmt.Fprintln(errOut, "status-report refresh:", err)
		return 1
	}
	return 0
}

// refreshStatus refreshes source projections and retains scope review requirements.
//
// Example: Refresh a report after a requirement change.
func refreshStatus(dir, event string) error {
	return refreshLinkedStatus(dir, event)
}

// invalidateStatus persists scope and diagnostic updates after a refresh failure.
//
// Example: Persist a diagnostic when a source cannot be read.
func invalidateStatus(dir string, diagnostics ...string) error {
	path := filepath.Join(dir, "latest-status-report.yaml")
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("report is not a regular file")
	}
	original, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if _, err := parse(original); err != nil {
		return fmt.Errorf("invalid report: %w", err)
	}
	updated := original
	for _, diagnostic := range diagnostics {
		updated, err = prepareInvalidation(updated, diagnostic)
		if err != nil {
			return err
		}
	}
	if bytes.Equal(updated, original) {
		return nil
	}
	if _, err := parse(updated); err != nil {
		return fmt.Errorf("refreshed report invalid: %w", err)
	}
	if err := verifyRefresh(original, updated, ledgerSource{}, forecastSource{}); err != nil {
		return fmt.Errorf("unsafe refresh: %w", err)
	}
	return publishStatus(dir, path, info, original, updated, nil)
}

// prepareInvalidation prepares a selective scope and diagnostic update.
//
// Example: Set scope incomplete and add the scope review diagnostic.
func prepareInvalidation(original []byte, diagnostic string) ([]byte, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(original, &doc); err != nil {
		return nil, err
	}
	root := doc.Content[0]
	var scope, blockers *yaml.Node
	for i := 0; i+1 < len(root.Content); i += 2 {
		switch root.Content[i].Value {
		case "scope_complete":
			scope = root.Content[i+1]
		case "blockers_risks":
			blockers = root.Content[i+1]
		}
	}
	if scope == nil || blockers == nil || scope.Kind != yaml.ScalarNode || blockers.Kind != yaml.SequenceNode {
		return nil, fmt.Errorf("unsupported report fields")
	}
	lines := strings.Split(string(original), "\n")
	// Only replace the scalar token; retain surrounding comments and layout.
	line := scope.Line - 1
	if line < 0 || line >= len(lines) {
		return nil, fmt.Errorf("unsupported scope layout")
	}
	start, err := yamlByteOffset([]byte(lines[line]), 1, scope.Column)
	if err != nil {
		return nil, err
	}
	if line < 0 || line >= len(lines) || start < 0 || start+len(scope.Value) > len(lines[line]) || lines[line][start:start+len(scope.Value)] != scope.Value {
		return nil, fmt.Errorf("unsupported scope layout")
	}
	lines[line] = lines[line][:start] + "false" + lines[line][start+len(scope.Value):]
	if blockers.Line == scope.Line && blockers.Column > scope.Column {
		blockers.Column += len("false") - len(scope.Value)
	}
	lines, err = appendDiagnostic(lines, blockers, diagnostic)
	if err != nil {
		return nil, err
	}
	updated := []byte(strings.Join(lines, "\n"))
	return updated, nil
}

// appendDiagnostic adds a missing diagnostic without changing existing entries.
//
// Example: Add a new risk to a flow-style blocker list.
func appendDiagnostic(lines []string, blockers *yaml.Node, diagnostic string) ([]string, error) {
	for _, n := range blockers.Content {
		if n.Value == diagnostic {
			return lines, nil
		}
	}
	if blockers.Style&yaml.FlowStyle == 0 {
		return appendBlockDiagnostic(lines, blockers, diagnostic)
	}
	i := blockers.Line - 1
	if i < 0 || i >= len(lines) {
		return nil, fmt.Errorf("unsupported blockers layout")
	}
	start, err := yamlByteOffset([]byte(lines[i]), 1, blockers.Column)
	if err != nil {
		return nil, err
	}
	if start < 0 || start >= len(lines[i]) {
		return nil, fmt.Errorf("unsupported blockers layout")
	}
	end, err := flowEnd([]byte(strings.TrimSuffix(lines[i], "\r")), start, token.SequenceStartType)
	if err != nil {
		return nil, err
	}
	sep := ""
	if len(blockers.Content) > 0 {
		sep = ", "
	}
	lines[i] = lines[i][:end] + sep + strconv.Quote(diagnostic) + lines[i][end:]
	return lines, nil
}

// appendBlockDiagnostic adds a diagnostic to a supported block-style list.
//
// Example: Append a diagnostic to an indented blocker list.
func appendBlockDiagnostic(lines []string, blockers *yaml.Node, diagnostic string) ([]string, error) {
	insert := blockers.Line - 1
	indent := "  "
	if len(blockers.Content) > 0 {
		last := blockers.Content[len(blockers.Content)-1]
		if last.Style&(yaml.LiteralStyle|yaml.FoldedStyle) != 0 || strings.Contains(last.Value, "\n") {
			return nil, fmt.Errorf("multiline blocker requires manual status refresh")
		}
		insert = last.Line
		if insert < 1 || insert > len(lines) {
			return nil, fmt.Errorf("unsupported blockers layout")
		}
		dash := strings.Index(lines[insert-1], "- ")
		if dash < 0 || strings.TrimSpace(lines[insert-1][:dash]) != "" {
			return nil, fmt.Errorf("unsupported blockers layout")
		}
		indent = lines[insert-1][:dash]
	}
	if insert < 0 || insert > len(lines) {
		return nil, fmt.Errorf("unsupported blockers layout")
	}
	ending := ""
	if len(lines) > 0 && strings.HasSuffix(lines[0], "\r") {
		ending = "\r"
	}
	return append(lines[:insert], append([]string{indent + "- " + strconv.Quote(diagnostic) + ending}, lines[insert:]...)...), nil
}

// publishStatus publishes a checked candidate using same-directory replacement.
//
// Example: Replace the report after checking its source files.
func publishStatus(dir, path string, info os.FileInfo, original, updated []byte, inputs map[string][]byte) error {
	temp, err := os.CreateTemp(dir, ".status-refresh-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if err = temp.Chmod(info.Mode().Perm()); err == nil {
		_, err = temp.Write(updated)
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	refreshBeforePublish()
	for p, before := range inputs {
		current, err := os.ReadFile(p)
		if err != nil {
			return fmt.Errorf("input changed during refresh: %w: %w", errRefreshRetry, err)
		}
		if !bytes.Equal(current, before) {
			return fmt.Errorf("input changed during refresh: %w", errRefreshRetry)
		}
	}
	current, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("report changed during refresh: %w: %w", errRefreshRetry, err)
	}
	if !current.Mode().IsRegular() || !os.SameFile(info, current) {
		return fmt.Errorf("report changed during refresh: %w", errRefreshRetry)
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("report changed during refresh: %w: %w", errRefreshRetry, err)
	}
	if !bytes.Equal(contents, original) {
		return fmt.Errorf("report changed during refresh: %w", errRefreshRetry)
	}
	return os.Rename(temp.Name(), path)
}
