package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// liveDependencySymlinkLimit bounds expansions consistently with filepath.EvalSymlinks.
//
// Example: a looping live-hook target retains known entries after 255 expansions.
const liveDependencySymlinkLimit = 255

// PathAccess describes how an operation uses its selected worktree names.
//
// Example: cached hunks select logical index names while staging content reads physical leaves.
type PathAccess int

const (
	// LogicalOnly selects index entries without reading selected worktree leaves.
	//
	// Example: unstaging a file preserves any worktree ancestor alias.
	LogicalOnly PathAccess = iota
	// PhysicalReadProbe reads content or probes absence under selected worktree names.
	//
	// Example: stage-content reads the selected file before updating the index.
	PhysicalReadProbe
	// PhysicalWrite changes selected worktree entries and protects live targets.
	//
	// Example: a move must protect both physical endpoints.
	PhysicalWrite
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
func liveProtectedPaths() ([]string, error) {
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
				paths = append(paths, filepath.Join(root, "hooks", name), candidate)
				for _, path := range []string{root, candidate} {
					dependencies, err := livePathDependencies(path)
					if err != nil {
						return nil, fmt.Errorf("trace live hook %q through %q: %w", candidate, path, err)
					}
					paths = append(paths, dependencies...)
				}
				// Resolve parent aliases while preserving the hook's own symlink entry.
				if entry, err := resolvedParent(candidate); err == nil {
					paths = append(paths, entry)
				}
				if referent, err := filepath.EvalSymlinks(candidate); err == nil {
					paths = append(paths, referent)
				}
			}
		}
	}
	for _, name := range []string{"CODEX_PROOF_ROOT", "KIMI_PROOF_ROOT"} {
		root := os.Getenv(name)
		if filepath.IsAbs(root) {
			paths = append(paths, filepath.Clean(root))
			entry, err := resolvedParent(root)
			if err != nil {
				return nil, fmt.Errorf("resolve proof root parent %q: %w", root, err)
			}
			paths = append(paths, entry)
			referent, err := filepath.EvalSymlinks(root)
			switch {
			case err == nil:
				paths = append(paths, referent)
			case errors.Is(err, os.ErrNotExist):
				// A not-yet-created proof root still protects its lexical entry.
			default:
				return nil, fmt.Errorf("resolve proof root %q: %w", root, err)
			}
		}
	}
	return paths, nil
}

// livePathDependencies records symlink entries consumed while resolving an absolute native path.
//
// Example: source/../hook retains source when source is an alias, even if hook ends elsewhere.
func livePathDependencies(path string) ([]string, error) {
	if !filepath.IsAbs(path) {
		return nil, fmt.Errorf("live dependency path must be absolute: %q", path)
	}
	separator := string(filepath.Separator)
	volume := filepath.VolumeName(path)
	resolved := volume + separator
	pending := strings.Split(path[len(volume):], separator)
	var dependencies []string
	expansions := 0
	for len(pending) != 0 {
		component := pending[0]
		pending = pending[1:]
		switch component {
		case "", ".":
			continue
		case "..":
			resolved = filepath.Dir(resolved)
			continue
		}
		entry := filepath.Join(resolved, component)
		info, err := os.Lstat(entry)
		switch {
		case errors.Is(err, os.ErrNotExist), errors.Is(err, os.ErrPermission), errors.Is(err, syscall.ENOTDIR):
			return dependencies, nil
		case err != nil:
			return nil, fmt.Errorf("inspect live dependency %q: %w", entry, err)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			if !info.IsDir() && len(pending) != 0 {
				return dependencies, nil
			}
			resolved = entry
			continue
		}
		dependencies = append(dependencies, entry)
		if expansions == liveDependencySymlinkLimit {
			return dependencies, nil
		}
		target, err := os.Readlink(entry)
		if err != nil {
			return nil, fmt.Errorf("read live dependency %q: %w", entry, err)
		}
		expansions++
		if filepath.IsAbs(target) {
			volume = filepath.VolumeName(target)
			resolved = volume + separator
			target = target[len(volume):]
		}
		// Expand the raw target before processing dotdot; cleaning it would erase dependencies.
		pending = append(strings.Split(target, separator), pending...)
	}
	return dependencies, nil
}

// CheckPaths rejects index escape and destructive writes to live control paths.
//
// Example: index-only hook staging is allowed while worktree restoration is denied.
func (r Repository) CheckPaths(
	operation Operation,
	access PathAccess,
) error {
	var protected []string
	if access == PhysicalWrite {
		var err error
		protected, err = liveProtectedPaths()
		if err != nil {
			return err
		}
	}
	for _, name := range operation.Paths {
		candidate := filepath.Join(r.Worktree, name)
		if !containsPath(r.Worktree, candidate) {
			return fmt.Errorf("logical path leaves worktree: %q", name)
		}
		pointer := filepath.Join(r.Worktree, ".git")
		if containsPath(r.GitDir, candidate) || containsPath(candidate, r.GitDir) || candidate == r.Index || containsPath(pointer, candidate) || containsPath(candidate, pointer) {
			return fmt.Errorf("operation targets logical Git control state: %q", name)
		}
		if access == LogicalOnly {
			continue
		}
		if operation.Kind == Restore && access == PhysicalWrite {
			if err := r.checkRestoreAncestors(name, protected); err != nil {
				return err
			}
		}
		resolved, err := resolvedParent(candidate)
		if err != nil {
			return fmt.Errorf("resolve path %q: %w", name, err)
		}
		if !containsPath(r.Worktree, resolved) {
			return fmt.Errorf("path leaves worktree through an ancestor alias: %q", name)
		}
		if containsPath(r.GitDir, resolved) || containsPath(resolved, r.GitDir) || resolved == r.Index || containsPath(pointer, resolved) || containsPath(resolved, pointer) {
			return fmt.Errorf("operation targets Git control state: %q", name)
		}
		if access != PhysicalWrite {
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

// checkRestoreAncestors diagnoses the first lexical alias before resolving deeper parents.
//
// Example: dir pointing to a regular file is named before inspecting dir/nested/file.
func (r Repository) checkRestoreAncestors(
	name string,
	protected []string,
) error {
	ancestor := r.Worktree
	components := strings.Split(name, string(filepath.Separator))
	for _, component := range components[:len(components)-1] {
		ancestor = filepath.Join(ancestor, component)
		info, err := os.Lstat(ancestor)
		switch {
		case errors.Is(err, os.ErrNotExist):
			return nil
		case err != nil:
			return fmt.Errorf("inspect restore ancestor %q for leaf %q: %w", ancestor, name, err)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			continue
		}
		for _, control := range protected {
			if containsPath(ancestor, control) || containsPath(control, ancestor) {
				return fmt.Errorf("protected live target or ancestor %q for restore leaf %q; edit source in place and stage exact content; index-only restore remains available", ancestor, name)
			}
		}
		// Native restore can replace this unnamed entry, so advise only its owned lexical move.
		relative, err := filepath.Rel(r.Worktree, ancestor)
		if err != nil {
			return fmt.Errorf("name restore ancestor %q for leaf %q: %w", ancestor, name, err)
		}
		return fmt.Errorf("restore leaf %q has existing ancestor symlink %q; move that exact owned ancestor entry to an unused owned name (mv -- <ancestor> <saved-alias>), then retry restore; index-only restore remains available", name, relative)
	}
	return nil
}
