package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

var refreshBeforePublish = func() {}

const refreshDiagnostic = "Requirement change requires scope review and status report refresh."

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

// refreshStatus only invalidates coverage; scope must be reviewed by its owner.
func refreshStatus(dir, event string) error {
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
	if event != "requirement_change" {
		return nil
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(original, &doc); err != nil {
		return err
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
		return fmt.Errorf("unsupported report fields")
	}
	lines := strings.Split(string(original), "\n")
	// Only replace the scalar token; retain surrounding comments and layout.
	line := scope.Line - 1
	start := scope.Column - 1
	if line < 0 || line >= len(lines) || start < 0 || start+len(scope.Value) > len(lines[line]) || lines[line][start:start+len(scope.Value)] != scope.Value {
		return fmt.Errorf("unsupported scope layout")
	}
	lines[line] = lines[line][:start] + "false" + lines[line][start+len(scope.Value):]
	found := false
	for _, n := range blockers.Content {
		if n.Value == refreshDiagnostic {
			found = true
		}
	}
	if !found {
		if blockers.Style&yaml.FlowStyle != 0 {
			i := blockers.Line - 1
			// Restrict flow edits to a single line, preserving all unrelated text.
			if i < 0 || i >= len(lines) {
				return fmt.Errorf("unsupported blockers layout")
			}
			start := blockers.Column - 1
			if start < 0 || start >= len(lines[i]) {
				return fmt.Errorf("unsupported blockers layout")
			}
			end := strings.Index(lines[i][start:], "]")
			if end < 0 {
				return fmt.Errorf("unsupported multiline blockers layout")
			}
			end += start
			sep := ""
			if len(blockers.Content) > 0 {
				sep = ", "
			}
			lines[i] = lines[i][:end] + sep + `"` + refreshDiagnostic + `"` + lines[i][end:]
		} else {
			insert := blockers.Line - 1
			if len(blockers.Content) > 0 {
				insert = blockers.Content[len(blockers.Content)-1].Line
			}
			if insert < 0 || insert > len(lines) {
				return fmt.Errorf("unsupported blockers layout")
			}
			lines = append(lines[:insert], append([]string{"  - \"" + refreshDiagnostic + "\""}, lines[insert:]...)...)
		}
	}
	updated := []byte(strings.Join(lines, "\n"))
	if bytes.Equal(updated, original) {
		return nil
	}
	if _, err := parse(updated); err != nil {
		return fmt.Errorf("refreshed report invalid: %w", err)
	}
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
	currentInfo, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !currentInfo.Mode().IsRegular() || !os.SameFile(info, currentInfo) {
		return fmt.Errorf("report changed during refresh; retry needed")
	}
	current, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if !bytes.Equal(current, original) {
		return fmt.Errorf("report changed during refresh; retry needed")
	}
	return os.Rename(temp.Name(), path)
}
