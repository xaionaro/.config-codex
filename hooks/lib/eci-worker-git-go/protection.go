package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// containsPath compares filesystem components rather than textual prefixes.
//
// Example: hooks-old does not contain hooks/validate-bash.sh.
func containsPath(
	parent string,
	child string,
) bool {
	relative, err := filepath.Rel(parent, child)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// resolvedParent resolves existing ancestors while keeping the selected leaf lexical.
//
// Example: removing a symlink changes its entry rather than its referent.
func resolvedParent(path string) (string, error) {
	parent, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err == nil {
		return filepath.Join(parent, filepath.Base(path)), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if filepath.Dir(path) == path {
		return "", err
	}
	parent, err = resolvedParent(filepath.Dir(path))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(path)), nil
}

// liveProtectedPaths enumerates the provider's live hooks and session-control roots.
//
// Example: destructive hooks-directory operations include protected live descendants.
func liveProtectedPaths() []string {
	roots := []string{os.Getenv("CODEX_CONFIGURED_HOME"), os.Getenv("CODEX_HOME"), os.Getenv("KIMI_CODE_HOME"),
		filepath.Join(os.Getenv("HOME"), ".codex"), filepath.Join(os.Getenv("HOME"), ".kimi-code")}
	paths := []string{}
	for _, root := range roots {
		if root == "" || !filepath.IsAbs(root) {
			continue
		}
		resolved, err := filepath.EvalSymlinks(root)
		if err != nil {
			continue
		}
		for _, name := range []string{"validate-bash.sh", "pretooluse-edit-dispatch.sh", "stop-gate.sh", "eci-active-gate.sh",
			"eci-review-gate.sh", "ate-orchestrator-gate.sh", "validate-edit-write.sh", "validate-apply-patch.sh"} {
			candidate := filepath.Join(resolved, "hooks", name)
			if _, err := os.Lstat(candidate); err == nil {
				paths = append(paths, candidate)
			}
		}
	}
	for _, name := range []string{"CODEX_PROOF_ROOT", "KIMI_PROOF_ROOT"} {
		root := os.Getenv(name)
		if filepath.IsAbs(root) {
			paths = append(paths, filepath.Clean(root))
		}
	}
	return paths
}

// CheckPaths rejects index escape and destructive writes to live control paths.
//
// Example: index-only hook staging is allowed while worktree restoration is denied.
func (r Repository) CheckPaths(
	paths []string,
	worktreeWrite bool,
) error {
	protected := liveProtectedPaths()
	for _, name := range paths {
		candidate := filepath.Join(r.Worktree, name)
		resolved, err := resolvedParent(candidate)
		if err != nil {
			return fmt.Errorf("resolve path %q: %w", name, err)
		}
		if !containsPath(r.Worktree, resolved) {
			return fmt.Errorf("path leaves worktree through an ancestor alias: %q", name)
		}
		if containsPath(r.GitDir, resolved) || containsPath(resolved, r.GitDir) || resolved == r.Index {
			return fmt.Errorf("operation targets Git control state: %q", name)
		}
		if !worktreeWrite {
			continue
		}
		for _, control := range protected {
			if resolved == control || containsPath(resolved, control) || containsPath(control, resolved) {
				return fmt.Errorf("protected live target or ancestor: %q; edit source in place and stage exact content", name)
			}
		}
	}
	return nil
}
