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

	"gopkg.in/yaml.v3"
)

var refreshBeforePublish = func() {}
var errRefreshRetry = errors.New("retry needed")

const refreshDiagnostic = "Requirement change requires scope review and status report refresh."

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
func refreshStatus(dir, event string) error {
	return refreshLinkedStatus(dir, event)
}

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
	return publishStatus(dir, path, info, original, updated, nil)
}

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
	start := scope.Column - 1
	if line < 0 || line >= len(lines) || start < 0 || start+len(scope.Value) > len(lines[line]) || lines[line][start:start+len(scope.Value)] != scope.Value {
		return nil, fmt.Errorf("unsupported scope layout")
	}
	lines[line] = lines[line][:start] + "false" + lines[line][start+len(scope.Value):]
	lines, err := appendDiagnostic(lines, blockers, diagnostic)
	if err != nil {
		return nil, err
	}
	updated := []byte(strings.Join(lines, "\n"))
	return updated, nil
}

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
	start := blockers.Column - 1
	if start < 0 || start >= len(lines[i]) {
		return nil, fmt.Errorf("unsupported blockers layout")
	}
	end, err := flowSequenceEnd(lines[i], start)
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

func flowSequenceEnd(line string, start int) (int, error) {
	if start >= len(line) || line[start] != '[' {
		return 0, fmt.Errorf("unsupported blockers layout")
	}
	var quote byte
	for i := start + 1; i < len(line); i++ {
		c := line[i]
		if quote == 0 {
			if c == ']' {
				return i, nil
			}
			if c == '\'' || c == '"' {
				quote = c
			}
			continue
		}
		if quote == '"' && c == '\\' {
			i++
			continue
		}
		if quote == '\'' && c == '\'' && i+1 < len(line) && line[i+1] == '\'' {
			i++
			continue
		}
		if c == quote {
			quote = 0
		}
	}
	return 0, fmt.Errorf("unsupported multiline blockers layout")
}

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
	return append(lines[:insert], append([]string{indent + "- " + strconv.Quote(diagnostic)}, lines[insert:]...)...), nil
}

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
